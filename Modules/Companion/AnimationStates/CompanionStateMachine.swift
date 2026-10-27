import AtlasCore
import Foundation

/// What the Companion is doing, shown by how the character moves (spec 6.3).
public enum CompanionState: String, CaseIterable, Sendable {
    case idle, listening, thinking, executing, success, failure, focus, sleeping

    public var title: String {
        switch self {
        case .idle: return "Idle"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .executing: return "Working"
        case .success: return "Done"
        case .failure: return "Something went wrong"
        case .focus: return "Focus"
        case .sleeping: return "Sleeping"
        }
    }
}

/// Turns what happens in ATLAS into one visible state. Driven by EventBus
/// events (and the command box), never by view code, and pure: the caller
/// passes the time, so tests can replay any sequence.
///
/// Each state stays up for a minimum time so quick runs don't flicker;
/// success and failure show for about 1.5 s, then the character returns to
/// whatever is underneath (more work, focus, idle or sleep).
public struct CompanionStateMachine: Sendable {
    public enum Input: Sendable, Equatable {
        case runStarted(UUID)
        case stepStarted(UUID)
        case runFinished(UUID, RunState)
        case commandOpened
        case commandParsing
        case commandParsed
        case commandClosed
        case focus(Bool)
        case macIdle(Bool)
        /// Anything the person did that should wake the character.
        case activity
    }

    public static let outcomeDuration: TimeInterval = 1.5
    public static let sleepAfter: TimeInterval = 600
    /// Timers can fire a few milliseconds early; don't wait another round for that.
    static let tolerance: TimeInterval = 0.01

    public static func minimumDuration(of state: CompanionState) -> TimeInterval {
        switch state {
        case .success, .failure: return outcomeDuration
        case .executing: return 0.8
        case .thinking: return 0.5
        case .listening: return 0.3
        case .idle, .focus, .sleeping: return 0
        }
    }

    public private(set) var displayed: CompanionState = .idle
    public private(set) var since: Date

    private var activeRuns: Set<UUID> = []
    private enum Interaction: Equatable { case none, listening, thinking }
    private var interaction: Interaction = .none
    /// Waiting to be shown, or showing (cleared 1.5 s after it appeared).
    private var outcome: CompanionState?
    private var isFocused = false
    private var isMacIdle = false
    private var lastActivity: Date

    public init(now: Date = Date()) {
        since = now
        lastActivity = now
    }

    /// Applies an input. Returns the new displayed state when it changed.
    @discardableResult
    public mutating func handle(_ input: Input, at now: Date) -> CompanionState? {
        switch input {
        case .runStarted(let id), .stepStarted(let id):
            activeRuns.insert(id)
            lastActivity = now
        case .runFinished(let id, let state):
            activeRuns.remove(id)
            lastActivity = now
            switch state {
            case .succeeded: outcome = .success
            case .failed, .partiallySucceeded: outcome = .failure
            default: break   // cancelled or skipped: no verdict to show
            }
        case .commandOpened:
            interaction = .listening
            lastActivity = now
        case .commandParsing:
            interaction = .thinking
            lastActivity = now
        case .commandParsed:
            interaction = .listening
        case .commandClosed:
            interaction = .none
            lastActivity = now
        case .focus(let on):
            isFocused = on
        case .macIdle(let idle):
            isMacIdle = idle
            if !idle { lastActivity = now }
        case .activity:
            lastActivity = now
        }
        return tick(at: now)
    }

    /// Advances timed transitions (outcome expiry, minimum times, sleep).
    @discardableResult
    public mutating func tick(at now: Date) -> CompanionState? {
        // An outcome that has had its time on screen is done.
        if let outcome, displayed == outcome, now.timeIntervalSince(since) + Self.tolerance >= Self.outcomeDuration {
            self.outcome = nil
        }
        let wanted = desired(at: now)
        guard wanted != displayed, now.timeIntervalSince(since) + Self.tolerance >= Self.minimumDuration(of: displayed) else { return nil }
        displayed = wanted
        since = now
        return wanted
    }

    /// When the next timed change could happen, so the caller can schedule
    /// one tick instead of polling. Nil when nothing is pending.
    public func nextDeadline(after now: Date) -> Date? {
        var deadlines: [Date] = []
        let wanted = desired(at: now)
        if wanted != displayed {
            deadlines.append(since.addingTimeInterval(Self.minimumDuration(of: displayed)))
        }
        if let outcome, displayed == outcome {
            deadlines.append(since.addingTimeInterval(Self.outcomeDuration))
        }
        if displayed != .sleeping, interaction == .none, activeRuns.isEmpty, outcome == nil {
            deadlines.append(lastActivity.addingTimeInterval(Self.sleepAfter))
        }
        return deadlines.filter { $0 > now }.min() ?? (wanted != displayed ? now : nil)
    }

    private func desired(at now: Date) -> CompanionState {
        switch interaction {
        case .listening: return .listening
        case .thinking: return .thinking
        case .none: break
        }
        if let outcome { return outcome }
        if !activeRuns.isEmpty { return .executing }
        if isFocused { return .focus }
        if isMacIdle || now.timeIntervalSince(lastActivity) >= Self.sleepAfter { return .sleeping }
        return .idle
    }

    /// Maps a bus event to an input, or nil if it doesn't concern the character.
    public static func input(for event: AtlasEvent) -> Input? {
        let runID = event.payload["runId"]?.stringValue.flatMap(UUID.init(uuidString:))
        switch event.name {
        case AtlasEvent.Name.workflowStarted:
            return runID.map(Input.runStarted)
        case AtlasEvent.Name.stepStarted:
            return runID.map(Input.stepStarted)
        case AtlasEvent.Name.workflowFinished:
            guard let runID else { return nil }
            let state = event.payload["state"]?.stringValue.flatMap(RunState.init(rawValue:)) ?? .failed
            return .runFinished(runID, state)
        default:
            return nil
        }
    }
}

/// How a state is drawn at a given animation intensity. With Reduce Motion
/// (or "Reduced"), motion is replaced by colour and opacity changes only;
/// "Still" shows a static image.
public struct CharacterPresentation: Equatable, Sendable {
    public enum Rendering: Equatable, Sendable { case animated, staticImage }

    public var rendering: Rendering
    /// Vertical float, in character heights.
    public var bobAmplitude: Double
    /// Seconds per float cycle.
    public var bobPeriod: Double
    /// Turns per second around the vertical axis (thinking, the orb's ring).
    public var spinSpeed: Double
    /// A one-off hop (success) or shake (failure).
    public var gesture: Gesture
    /// Glow colour of the eyes / core, as a hex string.
    public var accent: String
    public var opacity: Double
    public var eyesClosed: Bool

    public enum Gesture: Equatable, Sendable { case none, hop, shake, nod }

    public static func make(for state: CompanionState, intensity: CompanionSettings.Intensity, reduceMotion: Bool) -> CharacterPresentation {
        let accent: String
        switch state {
        case .idle: accent = "#7DD3FC"
        case .listening: accent = "#22D3EE"
        case .thinking: accent = "#A78BFA"
        case .executing: accent = "#FBBF24"
        case .success: accent = "#34D399"
        case .failure: accent = "#F87171"
        case .focus: accent = "#818CF8"
        case .sleeping: accent = "#64748B"
        }
        var presentation = CharacterPresentation(
            rendering: .animated, bobAmplitude: 0.04, bobPeriod: 3.2, spinSpeed: 0, gesture: .none,
            accent: accent, opacity: 1, eyesClosed: false
        )
        switch state {
        case .idle: break
        case .listening: presentation.bobAmplitude = 0.02; presentation.gesture = .nod
        case .thinking: presentation.spinSpeed = 0.35; presentation.bobPeriod = 2.4
        case .executing: presentation.bobAmplitude = 0.06; presentation.bobPeriod = 1.2; presentation.spinSpeed = 0.15
        case .success: presentation.gesture = .hop
        case .failure: presentation.gesture = .shake; presentation.bobAmplitude = 0.01
        case .focus: presentation.bobAmplitude = 0.01; presentation.bobPeriod = 6; presentation.opacity = 0.75
        case .sleeping: presentation.bobAmplitude = 0.015; presentation.bobPeriod = 6; presentation.opacity = 0.55; presentation.eyesClosed = true
        }
        if intensity == .still {
            presentation.rendering = .staticImage
        }
        if intensity != .full || reduceMotion {
            // Colour and opacity carry the state; nothing moves.
            presentation.bobAmplitude = 0
            presentation.spinSpeed = 0
            presentation.gesture = .none
        }
        return presentation
    }

    public var isStill: Bool { bobAmplitude == 0 && spinSpeed == 0 && gesture == .none }
}

extension CompanionState {
    /// Whether the live 3D view is worth its cost. A RealityKit view redraws
    /// every frame (about two-thirds of a CPU core even when still), so idle,
    /// focus and sleep show a rendered still image instead.
    public var usesLiveRendering: Bool {
        switch self {
        case .listening, .thinking, .executing, .success, .failure: return true
        case .idle, .focus, .sleeping: return false
        }
    }
}

/// Which finished runs get a speech bubble. Runs you started and every
/// failure always do; a successful automatic run (a file rule, a schedule)
/// at most once every 10 minutes per workflow, so a busy rule doesn't
/// chatter. Activation internals never do.
public struct BubblePolicy: Sendable {
    public static let quietInterval: TimeInterval = 10 * 60
    static let hiddenTriggers: Set<String> = ["space.activated", "space.transition", RunTrigger.subworkflow, "trigger.orbit.sweep"]

    private var lastShown: [UUID: Date] = [:]

    public init() {}

    public mutating func shouldShow(workflowID: UUID, trigger: String, state: RunState, at now: Date) -> Bool {
        guard !Self.hiddenTriggers.contains(trigger) else { return false }
        if state == .skipped { return trigger == RunTrigger.companion }
        let failed = state == .failed || state == .partiallySucceeded
        let automatic = trigger.hasPrefix(RunTrigger.automaticPrefix)
        if failed || !automatic {
            lastShown[workflowID] = now
            return true
        }
        if let last = lastShown[workflowID], now.timeIntervalSince(last) < Self.quietInterval { return false }
        lastShown[workflowID] = now
        return true
    }
}
