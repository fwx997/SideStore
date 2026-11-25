import Foundation

struct DownloadTransferStatus: Sendable {
    enum Phase: Sendable { case connecting, downloading, processing }
    var phase = Phase.connecting
    var received: Int64 = 0
    var expected: Int64 = 0
    var bytesPerSecond: Double = 0
    var lastDataTime: TimeInterval
    private var sampleBytes: Int64 = 0
    private var sampleTime: TimeInterval

    init(now: TimeInterval) { lastDataTime = now; sampleTime = now }

    mutating func record(received: Int64, expected: Int64, now: TimeInterval) {
        phase = .downloading
        self.received = max(0, received)
        self.expected = max(0, expected)
        lastDataTime = now
        let elapsed = now - sampleTime
        guard elapsed >= 0.3 else { return }
        bytesPerSecond = max(0, Double(received - sampleBytes) / elapsed)
        sampleTime = now
        sampleBytes = received
    }

    func text(now: TimeInterval) -> String {
        if phase == .connecting { return NSLocalizedString("Connecting to download server…", comment: "") }
        if phase == .processing { return NSLocalizedString("Download complete. Processing app…", comment: "") }
        let size = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        let total = expected > 0 ? " / " + ByteCountFormatter.string(fromByteCount: expected, countStyle: .file) : ""
        let idle = now - lastDataTime >= 3
        let rate = Int64(idle ? 0 : bytesPerSecond)
        let speed = (rate == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: rate, countStyle: .file)) + "/s"
        let prefix = idle ? NSLocalizedString("Waiting for data", comment: "") : NSLocalizedString("Downloading", comment: "")
        return "\(prefix) · \(size)\(total) · \(speed)"
    }
}

final class DownloadTransferStatusStore: @unchecked Sendable {
    static let shared = DownloadTransferStatusStore()
    private let lock = NSLock()
    private var transfers: [String: (id: UUID, value: DownloadTransferStatus)] = [:]

    func begin(for app: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> UUID {
        let id = UUID()
        lock.lock(); defer { lock.unlock() }
        transfers[app] = (id, DownloadTransferStatus(now: now))
        return id
    }

    func record(for app: String, id: UUID, received: Int64, expected: Int64,
                now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        guard var transfer = transfers[app], transfer.id == id else { return }
        transfer.value.record(received: received, expected: expected, now: now)
        transfers[app] = transfer
    }

    func processing(for app: String, id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard transfers[app]?.id == id else { return }
        transfers[app]?.value.phase = .processing
    }

    func remove(for app: String, id: UUID? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard id == nil || transfers[app]?.id == id else { return }
        transfers.removeValue(forKey: app)
    }

    func text(for app: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return transfers[app]?.value.text(now: ProcessInfo.processInfo.systemUptime)
    }
}
