#if os(macOS)
import AppKit
import Carbon.HIToolbox
import CoreServices
import IOKit.ps

/// Live trigger sources: NSWorkspace for apps and wake, FSEvents for
/// folders, Carbon hot keys for shortcuts, IOKit for power, and wall-clock
/// timers for schedules. All public, documented APIs.
public final class MacTriggerEnvironment: TriggerEnvironment, @unchecked Sendable {
    public init() {}

    public func now() -> Date { Date() }

    // MARK: Apps & wake

    public func observeApplications(_ handler: @escaping @Sendable (Bool, String, String) -> Void) -> TriggerToken {
        let center = NSWorkspace.shared.notificationCenter
        let observers = [(NSWorkspace.didLaunchApplicationNotification, true), (NSWorkspace.didTerminateApplicationNotification, false)]
            .map { name, launched in
                center.addObserver(forName: name, object: nil, queue: nil) { note in
                    guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                          app.activationPolicy == .regular, let bundleID = app.bundleIdentifier
                    else { return }
                    handler(launched, bundleID, app.localizedName ?? bundleID)
                }
            }
        return TriggerToken { observers.forEach(center.removeObserver) }
    }

    public func observeActivations(_ handler: @escaping @Sendable (String, String) -> Void) -> TriggerToken {
        let center = NSWorkspace.shared.notificationCenter
        let observer = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular, let bundleID = app.bundleIdentifier
            else { return }
            handler(bundleID, app.localizedName ?? bundleID)
        }
        return TriggerToken { center.removeObserver(observer) }
    }

    public func observeWake(_ handler: @escaping @Sendable () -> Void) -> TriggerToken {
        let center = NSWorkspace.shared.notificationCenter
        let observer = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
            // Give the network and displays a moment to come back.
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { handler() }
        }
        return TriggerToken { center.removeObserver(observer) }
    }

    // MARK: Folders

    public func watchFolder(_ path: String, _ handler: @escaping @Sendable ([FileChange]) -> Void) throws -> TriggerToken {
        let watcher = FolderWatcher(path: path, handler: handler)
        guard watcher.start() else { throw TriggerError("ATLAS couldn't watch “\(path)”.") }
        return TriggerToken { watcher.stop() }
    }

    // MARK: Shortcuts

    public func registerHotKey(_ key: HotKey, _ handler: @escaping @Sendable () -> Void) throws -> TriggerToken {
        let id = try onMain { try HotKeyCenter.shared.register(key, handler: handler) }
        return TriggerToken { DispatchQueue.main.async { HotKeyCenter.shared.unregister(id) } }
    }

    // MARK: Power

    public func observePower(_ handler: @escaping @Sendable (PowerStatus) -> Void) -> TriggerToken {
        let observer = PowerObserver(handler: handler)
        onMain { observer.start() }
        return TriggerToken { DispatchQueue.main.async { observer.stop() } }
    }

    // MARK: Schedules

    public func schedule(at date: Date, _ handler: @escaping @Sendable () -> Void) -> TriggerToken {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        // Wall clock: counts time asleep, so a missed time fires on wake (late).
        timer.schedule(wallDeadline: .now() + max(0, date.timeIntervalSinceNow), leeway: .seconds(1))
        timer.setEventHandler { handler() }
        timer.resume()
        return TriggerToken { timer.cancel() }
    }

    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }
}

/// One FSEvents stream with file-level events: direct children of the
/// folder, or (recursive) anything inside it.
final class FolderWatcher: @unchecked Sendable {
    let path: String
    let recursive: Bool
    let latency: CFTimeInterval
    let handler: @Sendable ([FileChange]) -> Void
    private var stream: FSEventStreamRef?
    private let queue: DispatchQueue

    init(path: String, recursive: Bool = false, latency: CFTimeInterval = 0.5, qos: DispatchQoS = .default,
         handler: @escaping @Sendable ([FileChange]) -> Void) {
        self.path = path
        self.recursive = recursive
        self.latency = latency
        self.handler = handler
        self.queue = DispatchQueue(label: "atlas.folder-watcher", qos: qos)
    }

    func start() -> Bool {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var changes: [FileChange] = []
            for index in 0..<min(count, list.count) {
                let flag = Int(flags[index])
                func has(_ value: Int) -> Bool { flag & value != 0 }
                let path = list[index].count > 1 && list[index].hasSuffix("/") ? String(list[index].dropLast()) : list[index]
                if has(kFSEventStreamEventFlagMustScanSubDirs) || has(kFSEventStreamEventFlagUserDropped)
                    || has(kFSEventStreamEventFlagKernelDropped) {
                    if watcher.recursive { changes.append(FileChange(path: path, kind: .rescan, isDirectory: true)) }
                    continue
                }
                let isDirectory = has(kFSEventStreamEventFlagItemIsDir)
                let kind: FileChange.Kind
                if has(kFSEventStreamEventFlagItemRemoved) && !FileManager.default.fileExists(atPath: path) {
                    kind = .removed
                } else if has(kFSEventStreamEventFlagItemRenamed) {
                    kind = FileManager.default.fileExists(atPath: path) ? .renamed : .removed
                } else if has(kFSEventStreamEventFlagItemCreated) {
                    kind = .created
                } else {
                    kind = .modified
                }
                if watcher.recursive {
                    guard FileLocation.isPath(path, inside: watcher.path), path != watcher.path else { continue }
                } else {
                    // Only direct children of the watched folder.
                    guard (path as NSString).deletingLastPathComponent == watcher.path else { continue }
                }
                changes.append(FileChange(path: path, kind: kind, isDirectory: isDirectory))
            }
            if !changes.isEmpty { watcher.handler(changes) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else { return false }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        return FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

/// Global hot keys through Carbon's RegisterEventHotKey, the supported way
/// to get system-wide shortcuts without Accessibility permission.
private final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private var handlers: [UInt32: (ref: EventHotKeyRef?, handler: @Sendable () -> Void)] = [:]
    private var nextID: UInt32 = 1
    private var installed = false

    func register(_ key: HotKey, handler: @escaping @Sendable () -> Void) throws -> UInt32 {
        installIfNeeded()
        var modifiers: UInt32 = 0
        if key.modifiers.contains(.command) { modifiers |= UInt32(cmdKey) }
        if key.modifiers.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if key.modifiers.contains(.option) { modifiers |= UInt32(optionKey) }
        if key.modifiers.contains(.control) { modifiers |= UInt32(controlKey) }
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(key.keyCode, modifiers, EventHotKeyID(signature: OSType(0x4154_4C53), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            throw TriggerError("\(key.display) is already used by macOS or another app. Pick a different shortcut.")
        }
        handlers[id] = (ref, handler)
        return id
    }

    func unregister(_ id: UInt32) {
        if let ref = handlers[id]?.ref { UnregisterEventHotKey(ref) }
        handlers[id] = nil
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?.handler()
    }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            HotKeyCenter.shared.fire(hotKey.id)
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// IOKit power source change notifications.
private final class PowerObserver: @unchecked Sendable {
    let handler: @Sendable (PowerStatus) -> Void
    private var source: CFRunLoopSource?

    init(handler: @escaping @Sendable (PowerStatus) -> Void) {
        self.handler = handler
    }

    func start() {
        let context = Unmanaged.passRetained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let observer = Unmanaged<PowerObserver>.fromOpaque(context).takeUnretainedValue()
            if let status = PowerSources.current() { observer.handler(status) }
        }, context)?.takeRetainedValue() else {
            Unmanaged<PowerObserver>.fromOpaque(context).release()
            return
        }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        // Report the starting state so changes can be detected.
        if let status = PowerSources.current() { handler(status) }
    }

    func stop() {
        guard let source else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        self.source = nil
        Unmanaged.passUnretained(self).release()
    }
}
#endif
