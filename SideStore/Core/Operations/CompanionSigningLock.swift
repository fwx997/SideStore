import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A shared advisory lock. Keep the file in place so all processes lock the
/// same inode; a crash releases the descriptor without stale-owner recovery.
final class CompanionSigningLock: @unchecked Sendable {
    private let state = NSLock()
    private let fileURL: URL
    private var descriptor: Int32 = -1
    private var holders: Set<UUID> = []

    init(directory: URL) { fileURL = directory.appendingPathComponent("LCCompanionSigning.lock") }

    func acquire() throws -> Lease {
        try state.withLock {
            if holders.isEmpty { descriptor = try openAndLock() }
            let identifier = UUID()
            holders.insert(identifier)
            return Lease(owner: self, identifier: identifier)
        }
    }

    private func openAndLock() throws -> Int32 {
        #if canImport(Darwin) || canImport(Glibc)
        let fd = open(fileURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Failure.unavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK || code == EAGAIN { throw Failure.busy }
            throw Failure.unavailable
        }
        return fd
        #else
        throw Failure.unavailable
        #endif
    }

    private func release(_ identifier: UUID) {
        state.withLock {
            guard holders.remove(identifier) != nil, holders.isEmpty else { return }
            #if canImport(Darwin) || canImport(Glibc)
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
            #endif
            descriptor = -1
        }
    }

    final class Lease: @unchecked Sendable {
        private let owner: CompanionSigningLock
        private let identifier: UUID
        fileprivate init(owner: CompanionSigningLock, identifier: UUID) {
            self.owner = owner
            self.identifier = identifier
        }
        func release() { owner.release(identifier) }
        deinit { release() }
    }

    enum Failure: LocalizedError {
        case busy
        case unavailable
        var errorDescription: String? {
            switch self {
            case .busy:
                return NSLocalizedString("SideInstaller is using signing or device services. Try again after its operation finishes.", comment: "")
            case .unavailable:
                return NSLocalizedString("The combined apps could not open their shared operation lock. Reinstall the complete combined package with its App Group enabled.", comment: "")
            }
        }
    }
}
