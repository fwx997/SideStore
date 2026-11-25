import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Kept wire-compatible with LiveContainer's SideStoreSupport counterpart.
// A completed error permits cleanup; an unfinished operation still needs its VPN.
struct ShortcutRefreshResult: Codable, Equatable, Sendable {
    static let pendingErrorDomain = "SideStore.ShortcutRefresh"
    static let pendingErrorCode = 1
    static let unknownErrorCode = 2

    let schemaVersion: Int
    let requestID: String
    let status: String
    let succeeded: Bool
    let canDisconnectVPN: Bool
    let message: String

    static func success(requestID: String, message: String) -> Self {
        Self(schemaVersion: 1, requestID: requestID, status: "success", succeeded: true, canDisconnectVPN: true, message: message)
    }

    static func failure(_ error: Error, requestID: String) -> Self {
        let marker = pendingError(in: error as NSError)
        let status = marker == nil ? "failed" : (marker?.code == unknownErrorCode ? "unknown" : "pending")
        return Self(schemaVersion: 1, requestID: requestID, status: status, succeeded: false,
                    canDisconnectVPN: marker == nil, message: error.localizedDescription)
    }

    static func pending(requestID: String, message: String) -> Self {
        Self(schemaVersion: 1, requestID: requestID, status: "pending", succeeded: false, canDisconnectVPN: false, message: message)
    }

    static func unknown(requestID: String, message: String) -> Self {
        Self(schemaVersion: 1, requestID: requestID, status: "unknown", succeeded: false, canDisconnectVPN: false, message: message)
    }

    static func pendingError(message: String) -> NSError {
        NSError(domain: pendingErrorDomain, code: pendingErrorCode,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func unknownError(message: String) -> NSError {
        NSError(domain: pendingErrorDomain, code: unknownErrorCode,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    var isTerminal: Bool { status == "success" || status == "failed" }

    func checkedForShortcut(returnErrorsAsResult: Bool) throws -> Self {
        guard !returnErrorsAsResult, status != "success" || !succeeded else { return self }
        if status == "pending" { throw Self.pendingError(message: message) }
        if status == "unknown" { throw Self.unknownError(message: message) }
        throw NSError(domain: Self.pendingErrorDomain, code: 3, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func localized(_ message: String) -> String {
        Bundle(for: ShortcutRefreshResultStore.self).localizedString(forKey: message, value: message, table: nil)
    }

    // Private AppIntents execution can wrap the original error. Preserve a pending
    // marker through that wrapper without sending arbitrary userInfo over XPC.
    static func transportError(_ error: Error) -> NSError {
        let original = error as NSError
        let classified = pendingError(in: original) ?? original
        return NSError(domain: classified.domain, code: classified.code,
                       userInfo: [NSLocalizedDescriptionKey: original.localizedDescription])
    }

    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else {
            let id = UUID(uuidString: requestID)?.uuidString ?? ""
            return #"{"schemaVersion":1,"requestID":"\#(id)","status":"unknown","succeeded":false,"canDisconnectVPN":false,"message":"Unable to encode refresh result."}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func pendingError(in error: NSError) -> NSError? {
        var current = error
        for _ in 0..<8 {
            if current.domain == pendingErrorDomain && [pendingErrorCode, unknownErrorCode].contains(current.code) { return current }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { return nil }
            current = underlying
        }
        return nil
    }
}

// Receipts live in the current physical host's App Group and survive either process.
// Only the real operation callback records success/failure after dispatch.
final class ShortcutRefreshResultStore: @unchecked Sendable {
    private struct Receipt: Codable {
        let schemaVersion: Int
        let hostBundleID: String
        let requestID: String
        let createdAt: Date
        var claimed: Bool
        var result: ShortcutRefreshResult
    }

    private let directory: URL
    private let hostBundleID: String
    private let now: @Sendable () -> Date
    private let lifetime: TimeInterval = 24 * 60 * 60

    init(group: URL, hostBundleID: String, now: @escaping @Sendable () -> Date = { Date() }) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        guard group.isFileURL, !hostBundleID.isEmpty, hostBundleID.count <= 255,
              hostBundleID != ".", hostBundleID != "..",
              hostBundleID.unicodeScalars.allSatisfy(allowed.contains) else {
            throw Self.storageError("The refresh result host is invalid.")
        }
        self.hostBundleID = hostBundleID
        self.now = now
        directory = group.appendingPathComponent("LiveContainer/SideStoreRefreshResults", isDirectory: true)
            .appendingPathComponent(hostBundleID, isDirectory: true)
    }

    func begin(requestID: String, message: String, allowExisting: Bool = false) throws {
        let id = try Self.canonicalID(requestID)
        try locked {
            let url = try fileURL(id)
            if FileManager.default.fileExists(atPath: url.path) {
                let old = try read(id)
                guard allowExisting, !old.claimed, old.result.status == "pending" else {
                    throw Self.storageError("This refresh request has already been used.")
                }
                return
            }
            let result = ShortcutRefreshResult.pending(requestID: id, message: message)
            try write(Receipt(schemaVersion: 1, hostBundleID: hostBundleID, requestID: id,
                              createdAt: now(), claimed: false, result: result))
        }
    }

    func claim(requestID: String) throws {
        try locked {
            var receipt = try read(requestID)
            guard !receipt.claimed, receipt.result.status == "pending" else {
                throw Self.storageError("This refresh request has already been used.")
            }
            receipt.claimed = true
            try write(receipt)
        }
    }

    func finish(_ result: ShortcutRefreshResult) throws {
        try locked {
            var receipt = try read(result.requestID)
            guard !receipt.result.isTerminal else { return }
            receipt.result = result
            try write(receipt)
        }
    }

    func query(requestID: String) -> ShortcutRefreshResult {
        do { return try read(requestID).result }
        catch {
            return .unknown(requestID: requestID, message: ShortcutRefreshResult.localized("This refresh result is missing, expired or unavailable. Keep the VPN connected until you verify the result in SideStore."))
        }
    }

    func acquireOperation() throws -> ShortcutRefreshOperationLease {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try ShortcutRefreshOperationLease(fileURL: directory.appendingPathComponent("active.lock"), nonblocking: true)
    }

    private func read(_ requestID: String) throws -> Receipt {
        let id = try Self.canonicalID(requestID)
        let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: fileURL(id)))
        let age = now().timeIntervalSince(receipt.createdAt)
        guard receipt.schemaVersion == 1, receipt.hostBundleID == hostBundleID, receipt.requestID == id,
              receipt.result.schemaVersion == 1, receipt.result.requestID == id,
              ["success", "failed", "pending", "unknown"].contains(receipt.result.status),
              receipt.result.succeeded == (receipt.result.status == "success"),
              receipt.result.canDisconnectVPN == receipt.result.isTerminal,
              age >= -60, age <= lifetime else { throw Self.storageError("The refresh result is expired or invalid.") }
        return receipt
    }

    private func write(_ receipt: Receipt) throws {
        try JSONEncoder().encode(receipt).write(to: fileURL(receipt.requestID), options: .atomic)
    }

    private func locked<T>(_ operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lease = try ShortcutRefreshOperationLease(fileURL: directory.appendingPathComponent("receipts.lock"), nonblocking: false)
        defer { lease.release() }
        return try operation()
    }

    private func fileURL(_ requestID: String) throws -> URL {
        directory.appendingPathComponent(try Self.canonicalID(requestID) + ".json")
    }

    private static func canonicalID(_ requestID: String) throws -> String {
        guard requestID.count == 36, let id = UUID(uuidString: requestID), id.uuidString == requestID.uppercased() else {
            throw storageError("The refresh request ID is invalid.")
        }
        return id.uuidString
    }

    private static func storageError(_ message: String) -> NSError {
        NSError(domain: "SideStore.ShortcutRefreshStorage", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

final class ShortcutRefreshOperationLease: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32

    init(fileURL: URL, nonblocking: Bool) throws {
        #if canImport(Darwin) || canImport(Glibc)
        let fd = open(fileURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard flock(fd, LOCK_EX | (nonblocking ? LOCK_NB : 0)) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK || code == EAGAIN {
                throw ShortcutRefreshResult.pendingError(message: ShortcutRefreshResult.localized("Another refresh task is in progress. This request was not started. Keep the VPN connected until that task finishes."))
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        descriptor = fd
        #else
        throw NSError(domain: "SideStore.ShortcutRefreshStorage", code: 2)
        #endif
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { return }
        #if canImport(Darwin) || canImport(Glibc)
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
        #endif
        descriptor = -1
    }

    deinit { release() }
}
