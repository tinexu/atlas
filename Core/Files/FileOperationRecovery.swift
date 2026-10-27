import Foundation

extension AtlasEvent.Name {
    /// Payload: operationId, kind, path, outcome. A half-done change was settled at launch.
    public static let fileOperationRecovered = "file.operation.recovered"
}

/// Settles file changes that were cut short (ATLAS quit or crashed between
/// "pending" and "done"). Never deletes anything: a partial copy left
/// behind goes to the Trash.
public enum FileOperationRecovery {
    public struct Result: Equatable, Sendable {
        public let operationID: UUID
        public let state: FileOperation.State
        public let message: String
    }

    @discardableResult
    public static func reconcile(store: AtlasStore, system: SystemAdapter, events: EventBus) async -> [Result] {
        guard let pending = try? store.pendingOperations(), !pending.isEmpty else { return [] }
        var results: [Result] = []
        for var operation in pending {
            let name = (operation.source as NSString).lastPathComponent
            let sourceThere = system.fileKind(atPath: operation.source) != .missing
            let destination = operation.destination
            let destinationThere = destination.map { system.fileKind(atPath: $0) != .missing } ?? false
            var message: String

            switch operation.kind {
            case .move, .rename:
                switch (sourceThere, destinationThere) {
                case (false, true):
                    operation.state = .done
                    message = "\(name) had finished moving before ATLAS stopped."
                case (true, false):
                    operation.state = .rolledBack
                    message = "\(name) hadn't moved yet, so nothing changed."
                case (true, true):
                    // A move across disks copies first; the original is intact.
                    _ = try? await system.trashItem(atPath: destination!)
                    operation.state = .rolledBack
                    message = "\(name) was half-moved. The original is where it was; the partial copy went to the Trash."
                case (false, false):
                    operation.state = .rolledBack
                    message = "\(name) couldn't be found in either place. Check the Trash and \(((destination ?? "") as NSString).deletingLastPathComponent)."
                }
            case .copy:
                if sourceThere, destinationThere, let destination,
                   system.fileSize(atPath: operation.source) == system.fileSize(atPath: destination) {
                    operation.state = .done
                    message = "The copy of \(name) had finished."
                } else {
                    if destinationThere, let destination { _ = try? await system.trashItem(atPath: destination) }
                    operation.state = .rolledBack
                    message = destinationThere ? "The copy of \(name) was incomplete and went to the Trash. Run it again." : "\(name) wasn't copied."
                }
            case .trash:
                operation.state = sourceThere ? .rolledBack : .done
                message = sourceThere ? "\(name) wasn't moved to the Trash." : "\(name) is in the Trash."
            case .createFolder, .tag:
                operation.state = .done
                message = "Finished."
            }
            operation.extra["recovered"] = message
            try? store.logOperation(operation)
            AtlasLog.engine.notice("Recovered file change \(operation.id.uuidString, privacy: .public): \(message, privacy: .public)")
            events.publish(AtlasEvent(AtlasEvent.Name.fileOperationRecovered, payload: [
                "operationId": .string(operation.id.uuidString), "kind": .string(operation.kind.rawValue),
                "path": .string(operation.source), "outcome": .string(operation.state.rawValue), "message": .string(message),
            ]))
            results.append(Result(operationID: operation.id, state: operation.state, message: message))
        }
        return results
    }
}
