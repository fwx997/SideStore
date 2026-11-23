import Foundation
import ObjectiveC

enum SharedCompanionSigningLock {
    private static let coordinator: CompanionSigningLock? = {
        let selector = NSSelectorFromString("lcAppGroupPath")
        if let method = class_getClassMethod(UserDefaults.self, selector) {
            typealias Getter = @convention(c) (AnyClass, Selector) -> NSString?
            let getter = unsafeBitCast(method_getImplementation(method), to: Getter.self)
            if let path = getter(UserDefaults.self, selector), path.length > 0 {
                return CompanionSigningLock(directory: URL(fileURLWithPath: path as String))
            }
        }
        guard let group = Bundle.main.altstoreAppGroup,
              let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return CompanionSigningLock(directory: directory)
    }()

    static func acquire() throws -> CompanionSigningLock.Lease? {
        let host = CombinedAppDistribution.hostURL(for: Bundle.Info.activeBundleURL)
        guard CombinedAppDistribution.requiresCompanions(at: host) else { return nil }
        guard let coordinator else { throw CompanionSigningLock.Failure.unavailable }
        return try coordinator.acquire()
    }
}

/// Covers work before per-app progress is published and nested sign-in flows.
/// This is local UI protection; it does not start or switch any application.
final class CompanionActivity: @unchecked Sendable {
    static let shared = CompanionActivity()
    private let lock = NSLock()
    private var operations: [UUID: String] = [:]

    func begin(_ reason: String) -> UUID {
        lock.withLock {
            let identifier = UUID()
            operations[identifier] = reason
            return identifier
        }
    }

    func end(_ identifier: UUID) {
        _ = lock.withLock { operations.removeValue(forKey: identifier) }
    }

    var reason: String? { lock.withLock { operations.values.first } }
}

@objc(SSCompanionActivityBridge)
final class SSCompanionActivityBridge: NSObject {
    @MainActor @objc static func switchBlockReason() -> String? {
        if let reason = CompanionActivity.shared.reason { return reason }
        guard AppManager.shared.isActivelyManagingAnyApp else { return nil }
        return "SideStore 正在安装、续签或管理应用，请完成后再切换。"
    }
}
