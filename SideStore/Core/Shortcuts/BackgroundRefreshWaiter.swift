// zh-patch: A shortcut deadline must not force the device to unlock or report success early.
import Foundation

enum BackgroundRefreshPendingError: LocalizedError {
    case stillRunning
    case notStarted

    var errorDescription: String? {
        switch self {
        case .stillRunning:
            return NSLocalizedString("Refresh is still running in the background. Keep the VPN connected and check Refresh Attempts in Settings for the final result. Refresh has not been confirmed yet.", comment: "")
        case .notStarted:
            return NSLocalizedString("Refresh could not start before the shortcut timed out. No refresh was started. Keep the VPN connected and try again.", comment: "")
        }
    }
}

final class BackgroundRefreshWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?

    func finish(_ result: Result<Void, Error>) {
        complete(result)
    }

    func waitForResult() async throws {
        try await withCheckedThrowingContinuation { continuation in
            install(continuation)
        }
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
        let completed: Result<Void, Error>? = lock.withLock {
            if let result { return result }
            self.continuation = continuation
            return nil
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

// This deadline includes network checks and database startup. An uncooperative startup
// task may return late, but it can never dispatch a refresh after the deadline wins.
@available(iOS 16.0, tvOS 16.0, macOS 13.0, *)
final class BackgroundRefreshSession: @unchecked Sendable {
    private let deadline: ContinuousClock.Instant
    private let lock = NSRecursiveLock()
    private let waiter = BackgroundRefreshWaiter()
    private var result: Result<Void, Error>?
    private var dispatched = false

    init(deadline: ContinuousClock.Instant) {
        self.deadline = deadline
    }

    func checkCanContinue() throws {
        try lock.withLock { try checkBeforeDispatch() }
    }

    func dispatch(_ operation: () throws -> Void) throws {
        try lock.withLock {
            try checkBeforeDispatch()
            dispatched = true
            // The factory is synchronous. A recursive lock permits its completion callback
            // to finish synchronously while keeping dispatch atomic against expiry/cancel.
            do { try operation() }
            catch { complete(.failure(error)); throw error }
        }
    }

    func finish(_ result: Result<Void, Error>) {
        lock.withLock { complete(result) }
    }

    func wait() async throws {
        let timer = Task {
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            expire()
        }
        defer { timer.cancel() }
        try await withTaskCancellationHandler {
            try await waiter.waitForResult()
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    private func checkBeforeDispatch() throws {
        try Task.checkCancellation()
        if let result {
            try result.get()
            throw CancellationError()
        }
        guard ContinuousClock.now < deadline else {
            let error = expirationError
            complete(.failure(error))
            throw error
        }
    }

    private var expirationError: BackgroundRefreshPendingError {
        dispatched ? .stillRunning : .notStarted
    }

    private func expire() {
        lock.withLock { complete(.failure(expirationError)) }
    }

    private func complete(_ result: Result<Void, Error>) {
        guard self.result == nil else { return }
        self.result = result
        waiter.finish(result)
    }
}
