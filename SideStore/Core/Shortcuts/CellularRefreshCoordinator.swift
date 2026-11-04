// zh-patch: Confirm shortcut completion and keep a recoverable cellular transaction.
// This coordinator deliberately has no UIKit dependency so its failure paths can be tested.
import Foundation

enum CellularRefreshError: LocalizedError, Equatable {
    case foregroundRequired
    case busy
    case shortcutRejected(String)
    case shortcutFailed(String)
    case shortcutCancelled(String)
    case shortcutTimedOut(String)
    case endpointNotReady
    case networkUnknown
    case recoveryRequired

    var errorDescription: String? {
        switch self {
        case .foregroundRequired:
            return NSLocalizedString("Cellular refresh requires the app to be open and the device unlocked. Open the app and refresh again, or use Wi-Fi for background refresh.", comment: "")
        case .busy:
            return NSLocalizedString("Another cellular operation is still running. Wait for it to finish and try again.", comment: "")
        case .shortcutRejected(let name):
            return String(format: NSLocalizedString("Could not open the shortcut '%@'. Check its name and run the refresh from the open app.", comment: ""), name)
        case .shortcutFailed(let name):
            return String(format: NSLocalizedString("The shortcut '%@' reported an error. Check its actions in Shortcuts.", comment: ""), name)
        case .shortcutCancelled(let name):
            return String(format: NSLocalizedString("The shortcut '%@' was cancelled.", comment: ""), name)
        case .shortcutTimedOut(let name):
            return String(format: NSLocalizedString("The shortcut '%@' did not confirm completion. Return to the app and try again.", comment: ""), name)
        case .endpointNotReady:
            return NSLocalizedString("The local device connection is not ready after turning off cellular data. Check the VPN and pairing file, then try again.", comment: "")
        case .networkUnknown:
            return NSLocalizedString("The current network could not be confirmed. Keep the app open, check the VPN, and try again.", comment: "")
        case .recoveryRequired:
            return NSLocalizedString("Cellular data restoration could not be confirmed. Use Restore Cellular Data in the app's settings, or turn cellular data on manually. The pending recovery has been saved.", comment: "")
        }
    }
}

final class CellularRefreshCoordinator: @unchecked Sendable {
    struct Settings: Sendable {
        let offName: String
        let onName: String
        let callbackScheme: String
        let offDelay: TimeInterval
        let onDelay: TimeInterval
    }

    struct Environment: Sendable {
        let shouldPause: @Sendable () async -> Bool
        let cellularAvailable: @Sendable () async -> Bool?
        let isForeground: @Sendable () async -> Bool
        let openURL: @Sendable (URL) async -> Bool
        let endpointReady: @Sendable () async -> Bool
        let pendingID: @Sendable () -> String?
        let savePendingID: @Sendable (String?) -> Void
        let settings: @Sendable () -> Settings
    }

    private struct Callback {
        let token: UUID
        let scheme: String
        var result: String?
    }

    @TaskLocal private static var taskOwner: UUID?
    private let environment: Environment
    private let lock = NSLock()
    private let callbackTimeout: TimeInterval
    private let ownerTimeout: TimeInterval
    private let readyTimeout: TimeInterval
    private var owner: UUID?
    private var paused = false
    private var disabling = false
    private var callback: Callback?
    private var restoration: Task<Bool, Error>?
    private var attemptedRecoveryID: String?

    init(environment: Environment, callbackTimeout: TimeInterval = 15,
         ownerTimeout: TimeInterval = 30, readyTimeout: TimeInterval = 3) {
        self.environment = environment
        self.callbackTimeout = callbackTimeout
        self.ownerTimeout = ownerTimeout
        self.readyTimeout = readyTimeout
    }

    // The outer scope owns cleanup; nested registration/signing helpers retain the same owner.
    func withRestorationScope<Value>(_ operation: () async throws -> Value) async throws -> Value {
        guard Self.taskOwner == nil else { return try await operation() }
        let identifier = UUID()
        return try await Self.$taskOwner.withValue(identifier) {
            try await acquireForScope(identifier)
            defer { release(identifier) }
            let result: Result<Value, Error>
            do { result = .success(try await operation()) }
            catch { result = .failure(error) }
            _ = try await restore(owner: identifier)
            return try result.get()
        }
    }

    @discardableResult
    func turnOffDataIfNeeded(addOnDelay: TimeInterval = 0) async throws -> Bool {
        guard await environment.shouldPause() else { return false }
        guard let identifier = Self.taskOwner else { throw CellularRefreshError.busy }
        try await acquire(identifier)
        if lock.withLock({ paused }) { return true }
        guard await environment.isForeground() else { throw CellularRefreshError.foregroundRequired }
        // An existing pending recovery must not be overwritten by a fresh disable request.
        guard environment.pendingID() == nil else { throw CellularRefreshError.recoveryRequired }
        guard let available = await environment.cellularAvailable() else { throw CellularRefreshError.networkUnknown }
        if !available {
            // No cellular path is not proof of the user's radio setting. Only proceed if
            // the existing device channel is usable, without changing the user's data state.
            try await waitForEndpoint()
            return false
        }
        guard lock.withLock({ !disabling }) else { throw CellularRefreshError.busy }
        lock.withLock { disabling = true; restoration = nil }
        defer { lock.withLock { disabling = false } }
        try Task.checkCancellation()

        let settings = environment.settings()
        environment.savePendingID(UUID().uuidString)
        do {
            try await runShortcut(name: settings.offName, scheme: settings.callbackScheme)
        } catch CellularRefreshError.shortcutRejected(_) {
            // The OS rejected launching the action, so this task has not disabled data.
            environment.savePendingID(nil)
            throw CellularRefreshError.shortcutRejected(settings.offName)
        }
        lock.withLock { paused = true }
        try await sleep(settings.offDelay + addOnDelay)
        try await waitForEndpoint()
        return true
    }

    @discardableResult
    func turnOnDataIfNeeded(addOnDelay: TimeInterval = 0) async throws -> Bool {
        guard let identifier = Self.taskOwner else { return false }
        return try await restore(owner: identifier, addOnDelay: addOnDelay)
    }

    // Called on activation, including a cold launch. Failed recovery is attempted only once
    // for this pending ID in a process, so returning from Shortcuts cannot create a loop.
    func recoverPendingData(allowRetry: Bool = false) async throws {
        guard await environment.isForeground(), let pendingID = environment.pendingID() else { return }
        let identifier: UUID? = lock.withLock {
            guard owner == nil, allowRetry || attemptedRecoveryID != pendingID else { return nil }
            let identifier = UUID()
            owner = identifier
            attemptedRecoveryID = pendingID
            return identifier
        }
        guard let identifier else { return }
        defer { release(identifier) }
        _ = try await restore(owner: identifier)
    }

    @discardableResult
    func handleCallback(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.lowercased() == "cellular-refresh",
              let rawToken = components.queryItems?.first(where: { $0.name == "token" })?.value,
              let token = UUID(uuidString: rawToken),
              ["/success", "/error", "/cancel"].contains(components.path) else { return false }
        return lock.withLock {
            guard var current = callback, current.token == token, current.result == nil,
                  current.scheme.caseInsensitiveCompare(components.scheme ?? "") == .orderedSame else { return false }
            current.result = components.path
            callback = current
            return true
        }
    }

    private func acquire(_ identifier: UUID) async throws {
        let deadline = Date().addingTimeInterval(ownerTimeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if tryAcquire(identifier) { return }
            try await sleep(0.1)
        }
        throw CellularRefreshError.busy
    }

    private func tryAcquire(_ identifier: UUID) -> Bool {
        lock.withLock {
            guard owner == nil || owner == identifier else { return false }
            owner = identifier
            return true
        }
    }

    private func acquireForScope(_ identifier: UUID) async throws {
        // Serialize the online phase too, before another operation can disable its network.
        if await environment.shouldPause() { try await acquire(identifier) }
    }

    private func release(_ identifier: UUID) {
        lock.withLock {
            guard owner == identifier else { return }
            owner = nil
            paused = false
            disabling = false
            callback = nil
            restoration = nil
        }
    }

    private func restore(owner identifier: UUID, addOnDelay: TimeInterval = 0) async throws -> Bool {
        let task: Task<Bool, Error>? = lock.withLock {
            guard owner == identifier, environment.pendingID() != nil else { return nil }
            if let restoration { return restoration }
            // Cleanup must still run when the signing operation has been cancelled.
            let task = Task.detached { try await self.performRestore(addOnDelay: addOnDelay) }
            restoration = task
            return task
        }
        guard let task else { return false }
        return try await task.value
    }

    private func performRestore(addOnDelay: TimeInterval) async throws -> Bool {
        let settings = environment.settings()
        do {
            try await waitForForeground()
            try await runShortcut(name: settings.onName, scheme: settings.callbackScheme)
        } catch {
            throw CellularRefreshError.recoveryRequired
        }
        // Success confirms that Shortcuts ran the configured action, not a radio setting API.
        environment.savePendingID(nil)
        lock.withLock { paused = false }
        try await sleep(settings.onDelay + addOnDelay)
        return true
    }

    private func runShortcut(name: String, scheme: String) async throws {
        guard await environment.isForeground() else { throw CellularRefreshError.foregroundRequired }
        let token = UUID()
        let url = Self.shortcutURL(name: name, scheme: scheme, token: token)
        lock.withLock { callback = Callback(token: token, scheme: scheme) }
        defer { clearCallback(token) }
        guard await environment.openURL(url) else { throw CellularRefreshError.shortcutRejected(name) }
        try await waitForCallback(token: token, name: name)
    }

    static func shortcutURL(name: String, scheme: String, token: UUID) -> URL {
        var url = URLComponents()
        url.scheme = "shortcuts"
        url.host = "x-callback-url"
        url.path = "/run-shortcut"
        url.queryItems = [URLQueryItem(name: "name", value: name)]
        for outcome in ["success", "error", "cancel"] {
            var callback = URLComponents()
            callback.scheme = scheme
            callback.host = "cellular-refresh"
            callback.path = "/" + outcome
            callback.queryItems = [URLQueryItem(name: "token", value: token.uuidString)]
            url.queryItems?.append(URLQueryItem(name: "x-" + outcome, value: callback.url!.absoluteString))
        }
        return url.url!
    }

    private func clearCallback(_ token: UUID) {
        lock.withLock {
            if callback?.token == token { callback = nil }
        }
    }

    private func waitForCallback(token: UUID, name: String) async throws {
        let deadline = Date().addingTimeInterval(callbackTimeout)
        while Date() < deadline {
            try Task.checkCancellation()
            let result = lock.withLock { callback?.token == token ? callback?.result : nil }
            if result == "/cancel" { throw CellularRefreshError.shortcutCancelled(name) }
            if result == "/error" { throw CellularRefreshError.shortcutFailed(name) }
            if result == "/success", await environment.isForeground() { return }
            try await sleep(0.1)
        }
        throw CellularRefreshError.shortcutTimedOut(name)
    }

    private func waitForForeground() async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if await environment.isForeground() { return }
            try await sleep(0.1)
        }
        throw CellularRefreshError.foregroundRequired
    }

    private func waitForEndpoint() async throws {
        let waiter = BackgroundRefreshWaiter()
        let probe = Task {
            do { try await pollEndpoint(); waiter.finish(.success(())) }
            catch { waiter.finish(.failure(error)) }
        }
        defer { probe.cancel() }
        do {
            try await waiter.wait(timeout: readyTimeout, onTimeout: {})
        } catch BackgroundRefreshPendingError.stillRunning {
            throw CellularRefreshError.endpointNotReady
        }
    }

    private func pollEndpoint() async throws {
        while true {
            try Task.checkCancellation()
            if await environment.endpointReady() { return }
            try await sleep(0.2)
        }
    }

    private func sleep(_ delay: TimeInterval) async throws {
        guard delay.isFinite, delay > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(min(delay, 30) * 1_000_000_000))
    }
}
