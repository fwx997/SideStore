// zh-patch: A shortcut deadline must not force the device to unlock or report success early.
import Foundation

enum BackgroundRefreshPendingError: LocalizedError {
    case stillRunning

    var errorDescription: String? {
        NSLocalizedString("Refresh is still running in the background. Keep the VPN connected and check the final notification. Refresh has not been confirmed yet.", comment: "")
    }
}

final class BackgroundRefreshWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?

    func finish(_ result: Result<Void, Error>) {
        complete(result)
    }

    func wait(timeout: TimeInterval, onTimeout: @escaping @Sendable () -> Void) async throws {
        let timer = Task {
            do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
            catch { return }
            complete(.failure(BackgroundRefreshPendingError.stillRunning), beforeResume: onTimeout)
        }
        defer { timer.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                install(continuation)
            }
        } onCancel: {
            // The owned background operation still reports its eventual outcome.
            self.complete(.failure(CancellationError()), beforeResume: onTimeout)
        }
    }

    private func install(_ continuation: CheckedContinuation<Void, Error>) {
        let completed = lock.withLock {
            if let result { return result }
            self.continuation = continuation
            return nil as Result<Void, Error>?
        }
        if let completed { continuation.resume(with: completed) }
    }

    private func complete(_ result: Result<Void, Error>, beforeResume: () -> Void = {}) {
        let completion: (Bool, CheckedContinuation<Void, Error>?) = lock.withLock {
            guard self.result == nil else { return (false, nil) }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            return (true, continuation)
        }
        guard completion.0 else { return }
        beforeResume()
        completion.1?.resume(with: result)
    }
}
