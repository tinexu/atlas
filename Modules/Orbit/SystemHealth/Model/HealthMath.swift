import AtlasCore
import Foundation

/// CPU time counters, summed over all cores.
public struct CPUTicks: Sendable, Equatable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    /// Busy share of the time between two readings, 0–100.
    public static func usage(from old: CPUTicks, to new: CPUTicks) -> Double {
        let busy = Double((new.user &- old.user) &+ (new.system &- old.system) &+ (new.nice &- old.nice))
        let idle = Double(new.idle &- old.idle)
        let total = busy + idle
        guard total > 0, new.user >= old.user, new.idle >= old.idle else { return 0 }
        return min(100, max(0, busy / total * 100))
    }
}

/// Page counts from the kernel's VM statistics.
public struct MemoryPages: Sendable, Equatable {
    public var pageSize: UInt64
    public var internalPages: UInt64
    public var purgeable: UInt64
    public var wired: UInt64
    public var compressed: UInt64

    public init(pageSize: UInt64, internalPages: UInt64, purgeable: UInt64, wired: UInt64, compressed: UInt64) {
        self.pageSize = pageSize
        self.internalPages = internalPages
        self.purgeable = purgeable
        self.wired = wired
        self.compressed = compressed
    }

    /// "Memory Used" as Activity Monitor counts it: app memory (internal
    /// minus purgeable) + wired + compressed.
    public var usedBytes: Int64 {
        let app = internalPages > purgeable ? internalPages - purgeable : 0
        return Int64((app + wired + compressed) * pageSize)
    }
}

/// A process using CPU or memory, where macOS lets ATLAS see it.
public struct ProcessUsage: Identifiable, Hashable, Sendable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let name: String
    public let cpu: Double
    public let memory: Int64
}

/// A warning the user sets, e.g. "free disk below 20 GB".
public struct HealthThreshold: Codable, Identifiable, Hashable, Sendable {
    public enum Metric: String, Codable, CaseIterable, Sendable {
        case diskFree, cpu, memory, battery

        public var title: String {
            switch self {
            case .diskFree: return "Free disk space below"
            case .cpu: return "CPU above"
            case .memory: return "Memory used above"
            case .battery: return "Battery below"
            }
        }

        public var unit: String { self == .diskFree ? "GB" : "%" }
        /// Warns when the value falls below the limit (rather than above).
        public var warnsBelow: Bool { self == .diskFree || self == .battery }
        /// How far past the limit it must recover before it can warn again.
        var recoveryMargin: Double {
            switch self {
            case .diskFree: return 2
            case .cpu: return 10
            case .memory: return 5
            case .battery: return 3
            }
        }
    }

    public var id: UUID
    public var metric: Metric
    public var value: Double
    /// Must stay crossed this long before it counts (e.g. CPU for 5 minutes).
    public var sustainedSeconds: Double
    public var isEnabled: Bool

    public init(id: UUID = UUID(), metric: Metric, value: Double, sustainedSeconds: Double = 0, isEnabled: Bool = true) {
        self.id = id
        self.metric = metric
        self.value = value
        self.sustainedSeconds = sustainedSeconds
        self.isEnabled = isEnabled
    }

    public static let defaults: [HealthThreshold] = [
        HealthThreshold(metric: .diskFree, value: 20),
        HealthThreshold(metric: .cpu, value: 90, sustainedSeconds: 300),
        HealthThreshold(metric: .battery, value: 15),
        HealthThreshold(metric: .memory, value: 90, sustainedSeconds: 300, isEnabled: false),
    ]

    /// The metric's current value, in the threshold's unit; nil if the Mac can't report it.
    public func reading(_ sample: HealthSample) -> Double? {
        switch metric {
        case .diskFree: return Double(sample.diskFree) / 1e9
        case .cpu: return sample.cpu
        case .memory: return sample.memoryPercent
        case .battery: return sample.battery
        }
    }

    public func isCrossed(_ value: Double) -> Bool {
        metric.warnsBelow ? value < self.value : value > self.value
    }

    func hasRecovered(_ value: Double) -> Bool {
        metric.warnsBelow ? value >= self.value + metric.recoveryMargin : value <= self.value - metric.recoveryMargin
    }

    public var summary: String {
        let amount = "\(ActionValue.number(value).displayString) \(metric.unit)"
        let duration = sustainedSeconds >= 60 ? " for \(Int(sustainedSeconds / 60)) min" : ""
        return "\(metric.title) \(amount)\(duration)"
    }

    public func message(for value: Double) -> String {
        let shown = metric == .diskFree ? String(format: "%.1f GB", value) : "\(Int(value.rounded()))%"
        switch metric {
        case .diskFree: return "Only \(shown) of disk space is free (warning below \(ActionValue.number(self.value).displayString) GB)."
        case .cpu: return "CPU has been at \(shown) for a while (warning above \(Int(self.value))%)."
        case .memory: return "Memory use is at \(shown) (warning above \(Int(self.value))%)."
        case .battery: return "Battery is at \(shown) (warning below \(Int(self.value))%)."
        }
    }
}

/// Decides when thresholds fire: once when crossed (and held for the
/// sustained time), and again only after recovering past a margin, so a
/// value hovering at the line doesn't warn over and over.
public struct ThresholdTracker: Sendable {
    public struct Firing: Sendable, Equatable {
        public let threshold: HealthThreshold
        public let value: Double
        public let message: String
    }

    private var crossedSince: [UUID: Date] = [:]
    private var fired: Set<UUID> = []

    public init() {}

    public mutating func update(_ sample: HealthSample, thresholds: [HealthThreshold]) -> [Firing] {
        var firings: [Firing] = []
        for threshold in thresholds {
            guard threshold.isEnabled, let value = threshold.reading(sample) else {
                crossedSince[threshold.id] = nil
                continue
            }
            if threshold.isCrossed(value) {
                let since = crossedSince[threshold.id] ?? sample.takenAt
                crossedSince[threshold.id] = since
                if !fired.contains(threshold.id), sample.takenAt.timeIntervalSince(since) >= threshold.sustainedSeconds {
                    fired.insert(threshold.id)
                    firings.append(Firing(threshold: threshold, value: value, message: threshold.message(for: value)))
                }
            } else {
                crossedSince[threshold.id] = nil
                if threshold.hasRecovered(value) { fired.remove(threshold.id) }
            }
        }
        return firings
    }
}
