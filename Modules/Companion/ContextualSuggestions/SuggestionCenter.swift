import AtlasCore
import Foundation

/// Watches ATLAS events and offers at most one suggestion every 15 minutes.
/// Each one shown is logged with its reason and published as
/// `companion.suggestion.shown`; accepting or dismissing is logged too.
public final class SuggestionCenter: @unchecked Sendable {
    public static let launchHistoryDays = 14

    private let store: AtlasStore
    private let events: EventBus
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var gate: SuggestionGate
    private var lastDisplayCount: Int?
    private var repetitionEnabled = true
    /// Called on the publishing thread with a suggestion to show.
    public var onSuggestion: (@Sendable (Suggestion) -> Void)?
    /// Resolves bundle IDs to app names for messages.
    public var appName: @Sendable (String) -> String? = { _ in nil }

    public init(store: AtlasStore, events: EventBus, settings: CompanionSettings, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.events = events
        self.now = now
        gate = SuggestionGate(muted: settings.mutedSuggestions, enabled: settings.suggestionsEnabled)
        repetitionEnabled = settings.repetitionDetection
    }

    public func update(settings: CompanionSettings) {
        lock.withLock {
            gate.muted = settings.mutedSuggestions
            gate.enabled = settings.suggestionsEnabled
            repetitionEnabled = settings.repetitionDetection
        }
    }

    // MARK: Inputs

    /// Feed every bus event here.
    public func handle(_ event: AtlasEvent) {
        switch event.name {
        case AtlasEvent.Name.workflowFinished:
            // Companion runs explain failures in the bubble already; this is for
            // automations that ran on their own.
            guard event.payload["state"]?.stringValue == RunState.failed.rawValue,
                  let trigger = event.payload["trigger"]?.stringValue, trigger.hasPrefix(RunTrigger.automaticPrefix),
                  let runID = event.payload["runId"]?.stringValue.flatMap(UUID.init(uuidString:)),
                  let run = try? store.run(id: runID)
            else { return }
            let explanation = FailureExplainer.explain(run, appName: appName)
            offer(Suggestion(kind: .workflowFailed, title: "“\(run.workflowName)” failed", detail: explanation.message,
                             reason: "An automation that started on its own (\(trigger)) failed at \(run.finishedAt?.formatted(date: .omitted, time: .shortened) ?? "just now").",
                             actionTitle: explanation.fixTitle ?? "Show Details", action: explanation.fix ?? .openRunHistory(run.id)))
        case AtlasEvent.Name.reviewAdded:
            let count = (try? store.reviewItems(state: .pending).count) ?? 0
            guard count > 0 else { return }
            offer(Suggestion(kind: .reviewQueue, title: "\(count) file\(count == 1 ? " is" : "s are") waiting for review",
                             detail: "A file rule wants your approval before it changes them.",
                             reason: "An Orbit rule added a file to the review queue (\(count) pending).",
                             actionTitle: "Review", action: .openReviewQueue))
        case AtlasEvent.Name.healthThreshold:
            guard event.payload["metric"]?.stringValue == "diskFree" else { return }
            offer(Suggestion(kind: .lowDisk, title: "Disk space is low", detail: "Want to review large files?",
                             reason: event.payload["message"]?.stringValue ?? "Free disk space dropped below your warning level.",
                             actionTitle: "Review Large Files", action: .openLargestFiles))
        case AtlasEvent.Name.displayChanged:
            let count = Int(event.payload["displayCount"]?.numberValue ?? 0)
            let previous = lock.withLock { () -> Int? in
                defer { lastDisplayCount = count }
                return lastDisplayCount
            }
            guard let previous, count > previous, let layout = layout(for: event) else { return }
            offer(Suggestion(kind: .displayConnected, title: "Apply your \(layout) layout?",
                             detail: "A display was connected (\(count) now).",
                             reason: "The number of displays went from \(previous) to \(count), and “\(layout)” was made for this arrangement.",
                             actionTitle: "Apply \(layout)", action: .applyLayout(layout)))
        default:
            break
        }
    }

    /// The layout made for the current display arrangement, if any.
    private func layout(for event: AtlasEvent) -> String? {
        let layouts = (try? store.windowLayouts()) ?? []
        let profileID = event.payload["profileId"]?.stringValue
        let count = Int(event.payload["displayCount"]?.numberValue ?? 0)
        return (layouts.first { $0.displayProfile?.id == profileID } ?? layouts.first { $0.displayProfile?.displays.count == count && count > 1 })?.name
    }

    /// Records an app the person opened (not one ATLAS launched), then checks
    /// for a repeated routine.
    public func recordManualLaunch(bundleID: String) {
        guard lock.withLock({ repetitionEnabled }) else { return }
        let date = now()
        try? store.recordAppLaunch(bundleID: bundleID, at: date)
        try? store.pruneAppLaunches(olderThan: date.addingTimeInterval(-Double(Self.launchHistoryDays) * 86_400))
        checkRepetition()
    }

    public func checkRepetition() {
        let date = now()
        guard let launches = try? store.appLaunches(since: date.addingTimeInterval(-Double(Self.launchHistoryDays) * 86_400)),
              let pattern = RepetitionDetector.detect(launches, excluding: RepetitionDetector.knownSequences(in: (try? store.workflows()) ?? []))
        else { return }
        let names = pattern.bundleIDs.map { appName($0) ?? $0 }
        offer(Suggestion(kind: .repetition, title: "Save “\(names.joined(separator: " → "))” as a workflow?",
                         detail: "You opened these together on \(pattern.days) different days.",
                         reason: "You opened \(names.joined(separator: ", ")) in that order within a few minutes on \(pattern.days) separate days in the last two weeks.",
                         actionTitle: "Open in Editor", action: .draftWorkflow(name: names.joined(separator: " + "), bundleIDs: pattern.bundleIDs)))
    }

    // MARK: Showing and answering

    @discardableResult
    public func offer(_ suggestion: Suggestion) -> Bool {
        let date = now()
        let allowed = lock.withLock { gate.offer(suggestion, at: date) }
        guard allowed else { return false }
        try? store.logSuggestion(suggestion, at: date)
        events.publish(AtlasEvent(AtlasEvent.Name.companionSuggestionShown, payload: payload(suggestion)))
        onSuggestion?(suggestion)
        return true
    }

    public func accepted(_ suggestion: Suggestion) {
        try? store.resolveSuggestion(id: suggestion.id, state: .accepted, at: now())
        events.publish(AtlasEvent(AtlasEvent.Name.companionSuggestionAccepted, payload: payload(suggestion)))
    }

    /// `forever`: "Don't suggest this again" for this kind.
    public func dismissed(_ suggestion: Suggestion, forever: Bool) {
        if forever { lock.withLock { gate.mute(suggestion.kind) } }
        try? store.resolveSuggestion(id: suggestion.id, state: forever ? .muted : .dismissed, at: now())
        events.publish(AtlasEvent(AtlasEvent.Name.companionSuggestionDismissed, payload: payload(suggestion).merging(["forever": .bool(forever)]) { $1 }))
    }

    public var mutedKinds: Set<String> { lock.withLock { gate.muted } }

    private func payload(_ suggestion: Suggestion) -> ActionParameters {
        ["suggestionId": .string(suggestion.id.uuidString), "kind": .string(suggestion.kind.rawValue),
         "title": .string(suggestion.title), "reason": .string(suggestion.reason)]
    }
}
