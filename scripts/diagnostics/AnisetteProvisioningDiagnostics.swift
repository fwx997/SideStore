import Foundation
import Testing
@testable import AnisetteKit

@Suite(.serialized)
struct AnisetteProvisioningDiagnostics {
    struct Observation: Codable {
        let variant: String
        let phase: String
        let outcome: String
        let status: Int?
    }

    @Test(.timeLimit(.minutes(3)))
    func compareInitializationClientInfo() async throws {
        AnisetteKitLogging.setLogging(false)
        let environment = ProcessInfo.processInfo.environment
        let libraries = URL(fileURLWithPath: try #require(environment["ANISETTE_DIAGNOSTIC_LIBS"]))
        let report = URL(fileURLWithPath: try #require(environment["ANISETTE_DIAGNOSTIC_REPORT"]))
        let original = AnisetteConstants.defaultClientInfo
        let corrected = original.replacingOccurrences(of: "<macOS;", with: "<Mac OS X;")
        var observations: [Observation] = []
        for (label, clientInfo) in [("original", original), ("Mac OS X", corrected)] {
            observations.append(await probeLoginHeader(label: label, clientInfo: clientInfo))
            observations.append(await probeProvisioning(label: label, clientInfo: clientInfo, libraries: libraries))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(observations).write(to: report, options: .atomic)
        for observation in observations {
            print("ANISETTE_PROBE \(observation.variant) | \(observation.phase) | \(observation.outcome) | \(observation.status ?? 0)")
        }
    }

    private func probeLoginHeader(label: String, clientInfo: String) async -> Observation {
        var request = URLRequest(url: URL(string: "https://gsa.apple.com/grandslam/GsService2")!)
        request.timeoutInterval = 15
        request.httpMethod = "POST"
        request.httpBody = Data("t".utf8)
        request.setValue(clientInfo, forHTTPHeaderField: "X-Mme-Client-Info")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return Observation(variant: label, phase: "empty-login-request", outcome: "HTTP response", status: (response as? HTTPURLResponse)?.statusCode)
        } catch {
            return Observation(variant: label, phase: "empty-login-request", outcome: "transport-error", status: (error as NSError).code)
        }
    }

    private func probeProvisioning(label: String, clientInfo: String, libraries: URL) async -> Observation {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            let client = try AnisetteClient(
                provisioningDir: temporary, clientInfo: clientInfo,
                provider: UnicornAnisetteDataProvider(), libraryDirectoryResolver: { libraries }
            )
            let headers = AnisetteRequestHeaders().with { $0.clientInfo = clientInfo }
            let (result, blob) = try await client.getAnisetteData(identifier: UUID(), storage: .memory(), headers: headers)
            let valid = !(result["X-Apple-I-MD"]?.isEmpty ?? true) && !(result["X-Apple-I-MD-M"]?.isEmpty ?? true) && !(blob?.isEmpty ?? true)
            return Observation(variant: label, phase: "provisioning", outcome: valid ? "success" : "missing-output", status: nil)
        } catch AnisetteError.httpError(let status, let message) {
            return Observation(variant: label, phase: "provisioning", outcome: message, status: status)
        } catch {
            return Observation(variant: label, phase: "provisioning", outcome: "non-http-error", status: (error as NSError).code)
        }
    }
}
