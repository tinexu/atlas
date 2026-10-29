import AtlasCore
import AtlasSpaces
import Foundation

/// The Creative Studio's headless half, installed once ATLAS's core is up.
public final class CreativeModule: @unchecked Sendable {
    public let service: CreativeService
    public let sessions: CreativeSessions
    public let rules: CreativeRules
    public let automations: CreativeAutomations

    public init(core: AtlasCore, thumbnails: ProjectThumbnails = ProjectThumbnails()) throws {
        service = CreativeService(core: core, thumbnails: thumbnails)
        sessions = CreativeSessions(core: core, service: service)
        sessions.restore()
        rules = CreativeRules(core: core, service: service)
        automations = CreativeAutomations(core: core, service: service)
        let actions: [any AtlasAction] = [
            OpenCreativeProjectAction(service: service), OpenDesignAppAction(service: service),
            FileExportAction(service: service), FileReferenceAction(service: service, sessions: sessions),
            RenderDoneAction(service: service), SaveVersionAction(service: service), SetExportModeAction(service: service),
            OpenInspirationAction(service: service), OpenAssetsAction(service: service),
            OfferStudioAction(service: service), ProjectOnEntryAction(service: service), StaleNudgeAction(service: service),
            WeeklyRecapAction(service: service),
        ]
        for action in actions where core.registry.descriptor(for: action.descriptor.id) == nil {
            try core.registry.register(action)
        }
    }

    /// What the room shows: the current project and the mug.
    public func roomState() -> CreativeRoomState {
        var state = service.roomState()
        state.mug = mug()
        state.pegboard = service.pegboardPictures()
        state.pegboardDetail = "Inspiration · \(service.inspirationFolder.abbreviatedPath) · drop pictures on the window to pin them"
        state.jars = service.jarColors()
        state.shelvesDetail = "Today's paint: " + state.jars.joined(separator: " ") + " · click for the project's assets"
        state.gallery = service.gallery()
        state.rug = sessions.rug()
        state.streak = sessions.streak()
        let days = state.rug.count
        state.rugDetail = "This month: \(days) creative day\(days == 1 ? "" : "s") · streak \(state.streak) day\(state.streak == 1 ? "" : "s")"
            + (state.streak >= 7 ? " · the neon's glowing for you" : "") + " · click for stats"
        return state
    }

    func mug() -> CreativeRoomState.Mug {
        let minutes = service.settings.sessionMinutes
        var mug = CreativeRoomState.Mug(refills: sessions.finishedCount,
                                        detail: "Click to start a \(CreativeMath.duration(Double(minutes) * 60)) creative session · right-click for more")
        if sessions.current != nil, let goal = sessions.goalSeconds {
            let left = CreativeMath.duration(max(0, goal - sessions.focusedSeconds()))
            mug.isRunning = sessions.isRunning
            mug.isPaused = sessions.isPaused
            mug.detail = sessions.isPaused ? "Paused · \(left) to go · click to resume" : "\(left) to go · click to pause · right-click for more"
        }
        return mug
    }
}
