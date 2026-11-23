import Foundation

func capabilityRequest() async throws {
    CapabilityProtocol.configure(status: 204)
    let portal = DeveloperPortal()
    let app = syntheticApp(features: [.appGroups: "true", .increasedMemoryLimit: " TRUE "])
    _ = try await portal.updateAppID(app, team: Team(), session: Session())
    precondition(portal.legacyParameters[Feature.increasedMemoryLimit.rawValue] == nil)
    precondition(portal.legacyParameters[Feature.appGroups.rawValue] as? Bool == true)
    precondition(CapabilityProtocol.requests.count == 1)
    let request = CapabilityProtocol.requests[0]
    precondition(request.httpMethod == "PATCH")
    precondition(request.url?.absoluteString == "https://apple.invalid/services/v1/bundleIds/APPID12345")
    precondition(request.value(forHTTPHeaderField: "X-Apple-GS-Token") == "synthetic-token")
    precondition(request.value(forHTTPHeaderField: "X-Apple-I-MD") == "synthetic-otp")
    precondition(request.value(forHTTPHeaderField: "Content-Type") == "application/vnd.api+json")
    let object = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
    let data = object["data"] as! [String: Any]
    let attributes = data["attributes"] as! [String: Any]
    precondition(attributes["name"] as? String == app.name, "App names were not JSON escaped")
    precondition(attributes["teamId"] as? String == Team().identifier)
    let relationships = data["relationships"] as! [String: Any]
    let bundleCapabilities = relationships["bundleIdCapabilities"] as! [String: Any]
    let capabilities = bundleCapabilities["data"] as! [[String: Any]]
    let capability = capabilities[0]
    precondition((capability["attributes"] as! [String: Any])["enabled"] as? Bool == true)
    let relationship = (capability["relationships"] as! [String: Any])["capability"] as! [String: Any]
    precondition((relationship["data"] as! [String: Any])["id"] as? String == "INCREASED_MEMORY_LIMIT")
}

func disabledCapabilities() async throws {
    let portal = DeveloperPortal()
    for request in [[:], [Feature.increasedMemoryLimit: "false"]] {
        CapabilityProtocol.configure(status: 204)
        _ = try await portal.updateAppID(syntheticApp(features: request), team: Team(), session: Session())
        precondition(CapabilityProtocol.requests.isEmpty, "A missing or disabled request enabled the capability")
        precondition(portal.legacyParameters[Feature.increasedMemoryLimit.rawValue] == nil)
    }
}

func capabilityResponses() async throws {
    let portal = DeveloperPortal()
    let valid = "{\"data\":{\"type\":\"bundleIds\",\"id\":\"APPID12345\"}}"
    let invalid: [(Int, String)] = [
        (301, valid), (302, valid), (303, valid), (307, valid), (308, valid),
        (403, ""), (500, valid), (200, ""), (200, "{}"), (200, "<html>Unavailable</html>"),
        (200, "{\"errors\":[{\"status\":\"409\",\"detail\":\"Synthetic refusal\"}]}"),
        (200, "{\"data\":{\"type\":\"bundleIds\",\"id\":\"ANOTHER\"}}"),
        (200, "{\"data\":{\"type\":\"capabilities\",\"id\":\"APPID12345\"}}")
    ]
    for (status, body) in invalid {
        CapabilityProtocol.configure(status: status, body: body)
        do {
            try await portal.enableCapabilities(["INCREASED_MEMORY_LIMIT"], for: syntheticApp(features: [:]), team: Team(), session: Session())
            preconditionFailure("Accepted invalid capability response \(status) \(body)")
        } catch is ServerError {}
    }
    CapabilityProtocol.configure(status: 200, body: valid)
    try await portal.enableCapabilities(["INCREASED_MEMORY_LIMIT", "INCREASED_MEMORY_LIMIT"], for: syntheticApp(features: [:]), team: Team(), session: Session())
    precondition(CapabilityProtocol.requests.count == 1)
}

func optionalCapabilityFailure() async throws {
    CapabilityProtocol.configure(status: 403, body: "{\"errors\":[{\"detail\":\"Synthetic refusal\"}]}")
    let app = syntheticApp(features: [.appGroups: "true", .increasedMemoryLimit: "true"])
    let updated = try await DeveloperPortal().updateAppID(app, team: Team(), session: Session())
    precondition(updated.features[.appGroups] == "true")
    precondition(updated.features[.increasedMemoryLimit] == nil, "A refused grant was reported as enabled")
    precondition(CapabilityProtocol.requests.count == 1)
}

func cancelledCapability() async throws {
    CapabilityProtocol.configure(status: 204)
    let task = Task {
        try await DeveloperPortal(cancelBeforeCapability: true).updateAppID(
            syntheticApp(features: [.increasedMemoryLimit: "true"]), team: Team(), session: Session()
        )
    }
    do {
        _ = try await task.value
        preconditionFailure("A cancelled capability update completed successfully")
    } catch is CancellationError {}
    precondition(CapabilityProtocol.requests.isEmpty, "Cancellation after the legacy response must prevent the capability request")

    let direct = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await DeveloperPortal().enableCapabilities(
            ["INCREASED_MEMORY_LIMIT"], for: syntheticApp(features: [:]), team: Team(), session: Session()
        )
    }
    do {
        try await direct.value
        preconditionFailure("An already cancelled direct capability request completed successfully")
    } catch is CancellationError {}
    precondition(CapabilityProtocol.requests.isEmpty, "An already cancelled task must not contact the capability endpoint")
}

func capabilityRedirect() async throws {
    let base = URL(string: "http://127.0.0.1:\(CommandLine.arguments[2])/services/v1/")!
    let portal = DeveloperPortal(servicesBaseURL: base, interceptRequests: false)
    do {
        try await portal.enableCapabilities(["INCREASED_MEMORY_LIMIT"], for: syntheticApp(features: [:]), team: Team(), session: Session())
        preconditionFailure("The authenticated capability request followed a redirect")
    } catch ServerError.underlyingError(let status, _) {
        precondition(status == 302, "Expected the original redirect response, got \(status)")
    }
}

@main
struct MemoryCapabilityRegression {
    static func main() async throws {
        let scenario = CommandLine.arguments[1]
        switch scenario {
        case "request": try await capabilityRequest()
        case "disabled": try await disabledCapabilities()
        case "responses": try await capabilityResponses()
        case "optional": try await optionalCapabilityFailure()
        case "cancelled": try await cancelledCapability()
        case "redirect": try await capabilityRedirect()
        default: preconditionFailure("Unknown scenario")
        }
        print("PASS", scenario)
    }
}
