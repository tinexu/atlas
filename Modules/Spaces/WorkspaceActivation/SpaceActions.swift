import AtlasCore
import Foundation

/// `space.activate`: makes Spaces usable from anywhere an action can run,
/// e.g. a keyboard shortcut, a workflow step or a future Companion command.
public struct SpaceActivateAction: AtlasAction {
    public static let id: ActionID = "space.activate"

    /// The registry owns this action and the activator reaches the registry
    /// through the engine, so hold the activator weakly to avoid a cycle.
    private final class ActivatorRef: @unchecked Sendable {
        weak var activator: SpaceActivator?
        init(_ activator: SpaceActivator) { self.activator = activator }
    }

    private let ref: ActivatorRef

    public let descriptor = ActionDescriptor(
        id: SpaceActivateAction.id,
        title: "Activate Space",
        summary: "Prepares your Mac for a Space by running its activation automation.",
        category: "Spaces",
        symbolName: "cube.transparent",
        parameters: [
            ParameterSpec(key: "space", label: "Space", kind: .text,
                          help: "Name of the Space, e.g. Coding Lab", choicesFrom: SpaceParameterChoices.spaces),
            ParameterSpec(key: "profile", label: "Profile", kind: .text, isRequired: false,
                          help: "Leave empty for the Space's default profile", choicesFrom: SpaceParameterChoices.profiles),
        ],
        sideEffects: [.launchesApplication],
        // Activating an active Space again only brings its apps forward.
        isIdempotent: true,
        // Waits for the whole activation, which may open several apps.
        defaultTimeout: 180
    )

    public init(activator: SpaceActivator) {
        self.ref = ActivatorRef(activator)
    }

    public func perform(_ parameters: ActionParameters, context: ActionContext) async throws -> ActionOutput {
        guard let activator = ref.activator else {
            throw ActionError.failed("Spaces aren't available right now.")
        }
        let reference = try parameters.requiredString("space")
        let activation = try await activator.activate(reference: reference, profile: parameters.optionalString("profile"))
        let run = activation.run
        let values: ActionParameters = [
            "spaceId": .string(activation.spaceID.uuidString),
            "profileId": .string(activation.profileID.uuidString),
            "runId": .string(run.id.uuidString),
            "state": .string(run.state.rawValue),
        ]

        // Honest status: anything short of a full activation is a failure
        // here, with the activation's own run holding the details.
        switch activation.status {
        case .ready:
            return ActionOutput("Activated \(reference)", values: values)
        case .partiallyReady(let succeeded, let total):
            throw ActionError.failed(
                "\(reference) is only partially ready (\(succeeded) of \(total) steps). \(run.error ?? "")"
                    .trimmingCharacters(in: .whitespaces)
            )
        default:
            throw ActionError.failed("\(reference) didn't activate. \(run.error ?? "")".trimmingCharacters(in: .whitespaces))
        }
    }
}
