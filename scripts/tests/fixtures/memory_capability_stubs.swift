import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AppID: Sendable {
    public let identifier: String
    public let name: String
    public let bundleIdentifier: String
    public var features: [Feature: String]
}
public struct Team: Sendable {
    public let identifier = "TESTTEAM12"
    public let name = "Synthetic personal team"
}
public struct Session: Sendable {
    public let dsid = "synthetic-account"
    public let authToken = "synthetic-token"
    public let xcodeVersion = "synthetic-xcode"
    public let anisetteData = AnisetteData()
}
public struct AnisetteData: Sendable {
    public let machineID = "synthetic-machine"
    public let oneTimePassword = "synthetic-otp"
    public let localUserID = "synthetic-local-user"
    public let routingInfo = "synthetic-routing"
    public let deviceID = "synthetic-device"
    public let clientInfo = "synthetic-client-info"
    public let clientTime = "synthetic-time"
    public let locale = "en_US"
    public let timeZone = "UTC"
}
public struct CustomHeaders: Sendable {
    public struct DeveloperServices: Sendable { public let userAgent = "synthetic-agent" }
    public struct GrandSlam: Sendable { public let authApp = "synthetic-auth-app" }
    public let developerServices = DeveloperServices()
    public let grandSlam = GrandSlam()
}
public enum ServerError: Error {
    case underlyingError(code: Int, message: String)
    case badServerResponse(reason: String, jsonPayload: String)
}
struct AppIDResponse { let appId: AppID? }
enum Constants {
    enum URLs {
        static let updateAppID = URL(string: "https://apple.invalid/services/legacy/updateAppId.action")!
    }
}
func debugLog(_ text: String) {}
func verboseLog(_ text: String) {}

public final class DeveloperPortal: @unchecked Sendable {
    let session: URLSession
    let servicesBaseURL: URL
    let customHeaders = CustomHeaders()
    let cancelBeforeCapability: Bool
    let lock = NSLock()
    private var parameters: [String: any Sendable] = [:]
    var legacyParameters: [String: any Sendable] { lock.withLock { parameters } }

    init(
        cancelBeforeCapability: Bool = false,
        servicesBaseURL: URL = URL(string: "https://apple.invalid/services/v1/")!,
        interceptRequests: Bool = true
    ) {
        self.cancelBeforeCapability = cancelBeforeCapability
        self.servicesBaseURL = servicesBaseURL
        let configuration = URLSessionConfiguration.ephemeral
        if interceptRequests { configuration.protocolClasses = [CapabilityProtocol.self] }
        session = URLSession(configuration: configuration)
    }

    func sendRequest<T>(url: URL, additionalParameters: [String: any Sendable], session: Session, team: Team) async throws -> T {
        try Task.checkCancellation()
        precondition(url == Constants.URLs.updateAppID)
        lock.withLock { parameters = additionalParameters }
        if cancelBeforeCapability { withUnsafeCurrentTask { $0?.cancel() } }
        return AppIDResponse(appId: syntheticApp(features: [.appGroups: "true"])) as! T
    }
}

final class CapabilityProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var code = 204
    nonisolated(unsafe) private static var data = Data()
    nonisolated(unsafe) private static var captured: [URLRequest] = []

    static func configure(status: Int, body: String = "") {
        lock.withLock {
            code = status
            data = Data(body.utf8)
            captured = []
        }
    }
    static var requests: [URLRequest] { lock.withLock { captured } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let result = Self.lock.withLock { () -> (Int, Data) in
            Self.captured.append(request)
            return (Self.code, Self.data)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: result.0, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func syntheticApp(features: [Feature: String]) -> AppID {
    AppID(identifier: "APPID12345", name: "Memory \"Example\" 中文", bundleIdentifier: "com.example.memory.TESTTEAM12", features: features)
}

func requestBody(_ request: URLRequest) -> Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var output = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        output.append(buffer, count: count)
    }
    return output
}
