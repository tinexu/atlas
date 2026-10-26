import AtlasCore
import Darwin
import Foundation
import IOKit

/// Reads how the Mac is doing. Behind a protocol so tests can feed values.
public protocol HealthSensor: Sendable {
    func sample() -> HealthSample
    func topProcesses(limit: Int) -> [ProcessUsage]
    /// Charge cycles, where the battery reports them.
    func batteryCycleCount() -> Int?
}

/// Public macOS APIs only: host_processor_info, host_statistics64, the
/// memory-pressure sysctl, volume capacity resource values, IOPowerSources
/// and libproc for this user's processes.
public final class MacHealthSensor: HealthSensor, @unchecked Sendable {
    private let lock = NSLock()
    private var lastTicks: CPUTicks?
    private var lastProcessTimes: [Int32: (UInt64, Date)] = [:]
    private let system: SystemAdapter
    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public init(system: SystemAdapter) {
        self.system = system
    }

    public func sample() -> HealthSample {
        let ticks = Self.cpuTicks()
        let cpu: Double = lock.withLock {
            defer { lastTicks = ticks ?? lastTicks }
            guard let ticks, let last = lastTicks else { return 0 }
            return CPUTicks.usage(from: last, to: ticks)
        }
        let memoryTotal = Int64(ProcessInfo.processInfo.physicalMemory)
        let memoryUsed = Self.memoryPages()?.usedBytes ?? 0
        let (free, total) = Self.disk()
        let power = system.powerStatus()
        return HealthSample(
            cpu: cpu, memoryUsed: memoryUsed, memoryTotal: memoryTotal, memoryPressure: Self.memoryPressure(),
            diskFree: free, diskTotal: total, battery: power.map { Double($0.batteryPercent) }, isCharging: power?.isCharging
        )
    }

    static func cpuTicks() -> CPUTicks? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info
        else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        var ticks = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        for cpu in 0..<Int(count) {
            let base = cpu * Int(CPU_STATE_MAX)
            ticks.user += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            ticks.system += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            ticks.idle += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            ticks.nice += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
        }
        return ticks
    }

    static func memoryPages() -> MemoryPages? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        return MemoryPages(pageSize: UInt64(pageSize), internalPages: UInt64(stats.internal_page_count),
                           purgeable: UInt64(stats.purgeable_count), wired: UInt64(stats.wire_count),
                           compressed: UInt64(stats.compressor_page_count))
    }

    /// 0 normal, 1 warning, 2 critical.
    static func memoryPressure() -> Int {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return 0 }
        switch level {
        case 4: return 2
        case 2: return 1
        default: return 0
        }
    }

    static func disk() -> (free: Int64, total: Int64) {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        return (values?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values?.volumeTotalCapacity ?? 0))
    }

    public func batteryCycleCount() -> Int? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "CycleCount" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? NSNumber)?.intValue
    }

    /// Busiest of this user's processes; others' aren't visible without admin rights.
    public func topProcesses(limit: Int) -> [ProcessUsage] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        let now = Date()
        var result: [ProcessUsage] = []
        var times: [Int32: (UInt64, Date)] = [:]
        let previous = lock.withLock { lastProcessTimes }
        for pid in pids.prefix(Int(max(0, filled))) where pid > 0 {
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { continue }
            let cpuTime = (info.pti_total_user + info.pti_total_system) * UInt64(timebase.numer) / UInt64(max(1, timebase.denom))
            times[pid] = (cpuTime, now)
            var cpu = 0.0
            if let (oldTime, oldDate) = previous[pid], cpuTime >= oldTime {
                let elapsed = now.timeIntervalSince(oldDate)
                if elapsed > 0 { cpu = Double(cpuTime - oldTime) / 1e9 / elapsed * 100 }
            }
            var nameBuffer = [CChar](repeating: 0, count: 256)
            proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            let name = String(cString: nameBuffer)
            result.append(ProcessUsage(pid: pid, name: name.isEmpty ? "Process \(pid)" : name, cpu: cpu, memory: Int64(info.pti_resident_size)))
        }
        lock.withLock { lastProcessTimes = times }
        return Array(result.sorted { $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.memory > $1.memory }.prefix(limit))
    }
}

/// Samples Mac Health on a schedule, keeps a week of history, and turns
/// crossed thresholds into `health.threshold` events that Flow can use.
public final class HealthMonitor: @unchecked Sendable {
    public static let thresholdsKey = "health.thresholds"
    public static let foregroundInterval: TimeInterval = 5
    public static let backgroundInterval: TimeInterval = 60

    private let sensor: HealthSensor
    private let store: AtlasStore
    private let events: EventBus
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "atlas.orbit.health", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var tracker = ThresholdTracker()
    private var visible = false
    private var lastDownsample = Date.distantPast
    private var lastStored = Date.distantPast
    private var _latest: HealthSample?
    private var _processes: [ProcessUsage] = []

    /// Called on a background queue after each reading.
    public var onSample: (@Sendable (HealthSample) -> Void)?

    public init(sensor: HealthSensor, store: AtlasStore, events: EventBus) {
        self.sensor = sensor
        self.store = store
        self.events = events
    }

    public var latest: HealthSample? { lock.withLock { _latest } }
    public var processes: [ProcessUsage] { lock.withLock { _processes } }
    public var interval: TimeInterval { lock.withLock { visible } ? Self.foregroundInterval : Self.backgroundInterval }

    public var thresholds: [HealthThreshold] {
        get { ((try? store.preference(Self.thresholdsKey, as: [HealthThreshold].self)) ?? nil) ?? HealthThreshold.defaults }
        set { try? store.setPreference(newValue, for: Self.thresholdsKey) }
    }

    public func start() {
        reschedule()
    }

    public func stop() {
        lock.withLock {
            timer?.cancel()
            timer = nil
        }
    }

    /// Every 5 seconds while Mac Health is on screen, every minute otherwise.
    public func setVisible(_ value: Bool) {
        let changed = lock.withLock { () -> Bool in
            defer { visible = value }
            return visible != value
        }
        if changed { reschedule() }
    }

    private func reschedule() {
        let interval = self.interval
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(Int(interval * 100)))
        timer.setEventHandler { [weak self] in self?.tick() }
        lock.withLock {
            self.timer?.cancel()
            self.timer = timer
        }
        timer.resume()
    }

    /// Takes one reading now. Internal so tests can drive it.
    func tick(now: Date = Date()) {
        var sample = sensor.sample()
        sample.takenAt = now
        let processes = lock.withLock { visible } ? sensor.topProcesses(limit: 8) : []
        record(sample, processes: processes)
    }

    func record(_ sample: HealthSample, processes: [ProcessUsage] = []) {
        let now = sample.takenAt
        let (firings, store) = lock.withLock { () -> ([ThresholdTracker.Firing], Bool) in
            _latest = sample
            if !processes.isEmpty { _processes = processes }
            // History at most every 5 seconds, even if sampled faster.
            let shouldStore = now.timeIntervalSince(lastStored) >= Self.foregroundInterval - 0.5
            if shouldStore { lastStored = now }
            return (tracker.update(sample, thresholds: thresholds), shouldStore)
        }
        if store {
            try? self.store.insertHealthSample(sample)
        }
        if now.timeIntervalSince(lock.withLock { lastDownsample }) > 600 {
            lock.withLock { lastDownsample = now }
            try? self.store.downsampleHealth(now: now)
        }
        var payload: ActionParameters = [
            "cpu": .number(sample.cpu.rounded()), "memoryPercent": .number(sample.memoryPercent.rounded()),
            "diskFree": .number(Double(sample.diskFree)),
        ]
        if let battery = sample.battery { payload["battery"] = .number(battery) }
        events.publish(AtlasEvent(AtlasEvent.Name.healthSample, payload: payload))
        for firing in firings {
            events.publish(AtlasEvent(AtlasEvent.Name.healthThreshold, payload: [
                "metric": .string(firing.threshold.metric.rawValue), "value": .number((firing.value * 10).rounded() / 10),
                "threshold": .number(firing.threshold.value), "message": .string(firing.message),
            ]))
        }
        onSample?(sample)
    }

    public func history(since: Date) -> [HealthSample] {
        (try? store.healthSamples(from: since)) ?? []
    }

    public func batteryCycleCount() -> Int? { sensor.batteryCycleCount() }
}
