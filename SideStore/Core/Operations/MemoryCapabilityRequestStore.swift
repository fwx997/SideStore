import Foundation

/// One-time tool requests live apart from the cache of the installed signature.
/// Revisions let a completed install consume only the request it actually used.
final class MemoryCapabilityRequestStore: @unchecked Sendable {
    static let shared = MemoryCapabilityRequestStore(defaults: .standard)
    private static let defaultsKey = "tools.pendingIncreasedMemoryRequests.v1"
    private let defaults: UserDefaults
    private let lock = NSLock()

    struct Request: Equatable, Sendable {
        let bundleIdentifier: String
        let revision: String
    }

    init(defaults: UserDefaults) { self.defaults = defaults }

    func recordEnabledCapabilityRequests(for bundleIdentifier: String, capabilities: [String]) {
        guard !bundleIdentifier.isEmpty, capabilities.contains("INCREASED_MEMORY_LIMIT") else { return }
        lock.withLock {
            var requests = read()
            requests[bundleIdentifier] = UUID().uuidString
            defaults.set(requests, forKey: Self.defaultsKey)
        }
    }

    func request(for bundleIdentifier: String) -> Request? {
        lock.withLock {
            let requests = read()
            return requests[bundleIdentifier].map { Request(bundleIdentifier: bundleIdentifier, revision: $0) }
        }
    }

    func consume(_ request: Request) {
        lock.withLock {
            var requests = read()
            guard requests[request.bundleIdentifier] == request.revision else { return }
            requests.removeValue(forKey: request.bundleIdentifier)
            defaults.set(requests, forKey: Self.defaultsKey)
        }
    }

    private func read() -> [String: String] {
        defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
    }
}
