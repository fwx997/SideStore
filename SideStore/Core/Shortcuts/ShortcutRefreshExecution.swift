import Foundation
import ObjectiveC

enum ShortcutRefreshEnvironment {
    static func store() throws -> ShortcutRefreshResultStore {
        let hostURL = CombinedAppDistribution.hostURL(for: Bundle.Info.activeBundleURL)
        guard let hostID = Bundle(url: hostURL)?.bundleIdentifier else {
            throw NSError(domain: "SideStore.ShortcutRefreshStorage", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "The physical refresh host could not be identified. No refresh was started."])
        }
        if let path = hostGroupPath(), path.hasPrefix("/") {
            return try ShortcutRefreshResultStore(group: URL(fileURLWithPath: path), hostBundleID: hostID)
        }
        guard let groupID = Bundle.main.altstoreAppGroup,
              let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            throw NSError(domain: "SideStore.ShortcutRefreshStorage", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "The refresh result App Group is unavailable. No refresh was started."])
        }
        return try ShortcutRefreshResultStore(group: group, hostBundleID: hostID)
    }

    private static func hostGroupPath() -> String? {
        let selector = NSSelectorFromString("lcAppGroupPath")
        guard let method = class_getClassMethod(UserDefaults.self, selector) else { return nil }
        typealias Getter = @convention(c) (AnyClass, Selector) -> NSString?
        let getter = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        return getter(UserDefaults.self, selector) as String?
    }
}

@available(iOS 17.0, tvOS 17.0, macOS 13.0, *)
final class ShortcutRefreshExecution: @unchecked Sendable {
    let progress: Progress
    private let requestID: String
    private let store: ShortcutRefreshResultStore
    private let session: BackgroundRefreshSession
    private let presentsNotifications: Bool
    private let completion: ((NSError?) -> Void)?
    private let lock = NSLock()
    private var completed = false
    private var lease: ShortcutRefreshOperationLease?

    init(requestID: String, progress: Progress, presentsNotifications: Bool,
         adoptExistingRequest: Bool = false, deadline: ContinuousClock.Instant = .now + .seconds(27),
         completion: ((NSError?) -> Void)? = nil) throws {
        self.requestID = requestID
        self.progress = progress
        self.presentsNotifications = presentsNotifications
        self.completion = completion
        session = BackgroundRefreshSession(deadline: deadline)
        store = try ShortcutRefreshEnvironment.store()
        try store.begin(requestID: requestID, message: ShortcutRefreshResult.localized("Refresh is preparing or still running. Keep the VPN connected until its final result is available."),
                        allowExisting: adoptExistingRequest)
        do {
            lease = try store.acquireOperation()
            try store.claim(requestID: requestID)
        } catch {
            try? store.finish(.failure(error, requestID: requestID))
            throw error
        }
    }

    func start() {
        Task {
            do { try await prepare() }
            catch { finish(.failure(error)) }
        }
    }

    func wait() async throws {
        do { try await session.wait() }
        catch {
            // A cancelled/expired preparation cannot dispatch later. A dispatched
            // operation retains this execution and alone records its final result.
            if !session.hasDispatched { finish(.failure(error)) }
            throw Self.shortcutError(error)
        }
    }

    private func prepare() async throws {
        try session.checkCanContinue()
        try await CellularRefreshManager.shared.checkBackgroundRefreshAllowed()
        try session.checkCanContinue()
        try await DatabaseManager.shared.start()
        try session.checkCanContinue()
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        let installedApps = await context.perform { InstalledApp.fetchAppsForRefreshingAll(in: context) }
        try session.checkCanContinue()
        guard !installedApps.isEmpty else { finish(.success(())); return }
        try session.dispatch {
            let operation = try AppManager.shared.backgroundRefresh(
                installedApps, presentsNotifications: presentsNotifications, ignoresServerNotFoundError: false
            ) { [self] result in
                finish(Self.refreshResult(result))
            }
            progress.addChild(operation.progress, withPendingUnitCount: 1)
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        let first = lock.withLock {
            guard !completed else { return false }
            completed = true
            return true
        }
        guard first else { return }
        var delivered = result.mapError(Self.shortcutError)
        let output = Self.output(delivered, requestID: requestID)
        do { try store.finish(output) }
        catch {
            delivered = .failure(ShortcutRefreshResult.unknownError(message: ShortcutRefreshResult.localized("The refresh finished but its result could not be saved. Check SideStore before disconnecting the VPN.")))
        }
        lease?.release()
        lease = nil
        // Persist before notifying either waiter: an extension can disappear here.
        session.finish(delivered)
        switch delivered {
        case .success: completion?(nil)
        case .failure(let error): completion?(ShortcutRefreshResult.transportError(error))
        }
    }

    private static func output(_ result: Result<Void, Error>, requestID: String) -> ShortcutRefreshResult {
        switch result {
        case .success:
            return .success(requestID: requestID, message: ShortcutRefreshResult.localized("All apps have been refreshed."))
        case .failure(let error):
            return .failure(error, requestID: requestID)
        }
    }

    private static func shortcutError(_ error: Error) -> Error {
        switch error {
        case BackgroundRefreshPendingError.stillRunning, CellularRefreshError.busy, CompanionSigningLock.Failure.busy:
            return ShortcutRefreshResult.pendingError(message: error.localizedDescription)
        default:
            return error
        }
    }

    private static func refreshResult(_ result: Result<[String: Result<InstalledApp, Error>], Error>) -> Result<Void, Error> {
        do {
            let results = try result.get()
            for result in results.values { _ = try result.get() }
            return .success(())
        } catch OperationError.noInstalledApps {
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}

@available(iOS 17.0, tvOS 17.0, macOS 13.0, *)
@objc(SSBackgroundRefreshBridge)
final class SSBackgroundRefreshBridge: NSObject {
    @objc(startRefreshWithRequestIdentifier:completion:)
    static func startRefresh(requestIdentifier: String, completion: @escaping (NSError?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        do {
            let execution = try ShortcutRefreshExecution(requestID: requestIdentifier, progress: progress,
                                                         presentsNotifications: false, adoptExistingRequest: true,
                                                         completion: completion)
            execution.start()
            Task { try? await execution.wait() }
        } catch {
            completion(ShortcutRefreshResult.transportError(error))
        }
        return progress
    }
}
