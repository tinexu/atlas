import Foundation

/// Starter automations created on first launch. They only use apps that
/// ship with macOS, so they run on any Mac without setup.
public enum SampleWorkflows {
    public static var all: [Workflow] { [codingSetup, morningSetup, focusReset] }

    /// A preview of what the Coding Lab Space will trigger in Stage 02.
    public static var codingSetup: Workflow {
        Workflow(
            name: "Coding Setup",
            summary: "Terminal, documentation and your home folder, ready to go. This becomes the Coding Lab's activation in Stage 02.",
            steps: [
                WorkflowStep(actionID: LaunchApplicationAction.id, parameters: ["bundleId": "com.apple.Terminal"]),
                WorkflowStep(actionID: OpenURLAction.id, parameters: ["url": "https://developer.apple.com/documentation/swift"]),
                WorkflowStep(actionID: RevealInFinderAction.id, parameters: ["path": "~"]),
                WorkflowStep(actionID: LogMessageAction.id, parameters: ["message": "Coding setup ready"]),
            ]
        )
    }

    public static var morningSetup: Workflow {
        Workflow(
            name: "Morning Setup",
            summary: "Opens Calendar, Reminders and Notes, then lets you know everything is ready.",
            failurePolicy: .continueOnFailure,
            steps: [
                WorkflowStep(actionID: LaunchApplicationAction.id, parameters: ["bundleId": "com.apple.iCal"]),
                WorkflowStep(actionID: LaunchApplicationAction.id, parameters: ["bundleId": "com.apple.reminders"]),
                WorkflowStep(actionID: LaunchApplicationAction.id, parameters: ["bundleId": "com.apple.Notes"]),
                WorkflowStep(actionID: ShowNotificationAction.id, parameters: [
                    "title": "Good morning",
                    "body": "Calendar, Reminders and Notes are open.",
                ]),
            ]
        )
    }

    /// Demonstrates a confirmation-gated step.
    public static var focusReset: Workflow {
        Workflow(
            name: "Focus Reset",
            summary: "Quits Music (after asking you), waits a moment, then opens Notes. Shows how ATLAS asks before anything disruptive.",
            steps: [
                WorkflowStep(actionID: QuitApplicationAction.id, parameters: ["bundleId": "com.apple.Music"]),
                WorkflowStep(actionID: DelayAction.id, parameters: ["seconds": 1]),
                WorkflowStep(actionID: LaunchApplicationAction.id, parameters: ["bundleId": "com.apple.Notes"]),
            ]
        )
    }
}
