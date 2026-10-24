import Foundation

/// Runs `operation`, failing with `ActionError.timedOut` if it takes longer
/// than `seconds`. Unlike a task group, this returns as soon as the deadline
/// passes even if the operation ignores cancellation (many system calls do),
/// so one stuck app can't hang a whole workflow.
func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let race = TimeoutRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.install(continuation)
            race.add(Task {
                do { race.finish(.success(try await operation())) }
                catch { race.finish(.failure(error)) }
            })
            race.add(Task {
                let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                race.finish(.failure(ActionError.timedOut(seconds)))
            })
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

/// Resumes a continuation exactly once, whichever side finishes first, and
/// cancels the loser. Safe against any ordering of install/add/finish.
private final class TimeoutRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?
    private var tasks: [Task<Void, Never>] = []

    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func add(_ task: Task<Void, Never>) {
        lock.lock()
        let alreadyFinished = result != nil
        if !alreadyFinished { tasks.append(task) }
        lock.unlock()
        if alreadyFinished { task.cancel() }
    }

    func finish(_ outcome: Result<T, Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = outcome
        let continuation = self.continuation
        self.continuation = nil
        let pending = tasks
        tasks = []
        lock.unlock()

        pending.forEach { $0.cancel() }
        continuation?.resume(with: outcome)
    }
}
