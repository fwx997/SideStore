import Foundation

private let memory = "com.apple.developer.kernel.increased-memory-limit"
private let addressing = "com.apple.developer.kernel.extended-virtual-addressing"
private let mainID = "com.example.vm.TESTTEAM"
private let helperID = mainID + ".Helper"

func expect(_ actual: Bool?, _ expected: Bool?, _ label: String) {
    precondition(actual == expected, "\(label): expected \(String(describing: expected)), got \(String(describing: actual))")
}

func fixture(at root: URL, original: [String: any Sendable]) throws -> (AppBundle, [ProvisioningProfile]) {
    let appURL = root.appendingPathComponent("Test.app")
    let helperURL = appURL.appendingPathComponent("PlugIns/Helper.appex")
    try FileManager.default.createDirectory(at: helperURL, withIntermediateDirectories: true)
    try writePlist(["CFBundleIdentifier": mainID], to: appURL.appendingPathComponent("Info.plist"))
    try writePlist(["CFBundleIdentifier": helperID], to: helperURL.appendingPathComponent("Info.plist"))
    try writePlist(original, to: appURL.appendingPathComponent("Signature.plist"))
    try writePlist(["get-task-allow": true], to: helperURL.appendingPathComponent("Signature.plist"))
    let profiles = [mainID, helperID].map { identifier in
        ProvisioningProfile(
            name: "Test profile",
            bundleIdentifier: identifier,
            teamIdentifier: "TESTTEAM",
            entitlements: ["application-identifier": "TESTTEAM." + identifier, "get-task-allow": true],
            data: Data(("unchanged profile bytes: " + identifier).utf8)
        )
    }
    return (AppBundle(fileURL: appURL)!, profiles)
}

func originalPackage(_ root: URL) async throws {
    let (app, profiles) = try fixture(
        at: root, original: [memory: true, addressing: true, "dynamic-codesigning": true]
    )
    let signer: any CodeSignerAPI = AppBundleSigner(team: Team(), keyStore: KeyStore())
    try await signer.signApp(at: app.fileURL, provisioningProfiles: profiles, progress: nil)
    expect(app.entitlements[memory] as? Bool, true, "original memory request")
    expect(app.entitlements[addressing] as? Bool, true, "original address-space request")
    expect(app.entitlements["dynamic-codesigning"] as? Bool, nil, "unapproved private entitlement")
    expect(app.appExtensions.first!.entitlements[memory] as? Bool, nil, "main request cannot reach helper")
    for (bundle, profile) in [(app, profiles[0]), (app.appExtensions.first!, profiles[1])] {
        let embedded = try Data(contentsOf: bundle.fileURL.appendingPathComponent("embedded.mobileprovision"))
        precondition(embedded == profile.data, "The signed provisioning profile was modified")
    }
}

func cachedPackage(_ root: URL) async throws {
    let (app, profiles) = try fixture(at: root, original: ["get-task-allow": true])
    let signer = AppBundleSigner(team: Team(), keyStore: KeyStore())
    try await signer.signApp(
        at: app.fileURL, provisioningProfiles: profiles,
        customEntitlements: [mainID: ["get-task-allow": true, memory: true]]
    )
    expect(app.entitlements[memory] as? Bool, true, "custom memory request on stripped cached app")
    expect(app.appExtensions.first!.entitlements[memory] as? Bool, nil, "helper isolation")
}

func disabledAndRemoved(_ root: URL) async throws {
    let (app, profiles) = try fixture(at: root, original: [memory: true, addressing: true])
    let signer = AppBundleSigner(team: Team(), keyStore: KeyStore())
    try await signer.signApp(
        at: app.fileURL, provisioningProfiles: profiles,
        customEntitlements: [mainID: [memory: false, addressing: false]]
    )
    expect(app.entitlements[memory] as? Bool, false, "explicit false overrides original true")
    expect(app.entitlements[addressing] as? Bool, false, "explicit false address-space request")
    try await signer.signApp(
        at: app.fileURL, provisioningProfiles: profiles, customEntitlements: [mainID: [:]]
    )
    expect(app.entitlements[memory] as? Bool, nil, "removed request")
    expect(app.entitlements["get-task-allow"] as? Bool, true, "mandatory profile entitlement")
}

func targetsAndCache(_ root: URL) async throws {
    let (app, profiles) = try fixture(at: root, original: ["get-task-allow": true])
    let signer = AppBundleSigner(team: Team(), keyStore: KeyStore())
    try await signer.signApp(
        at: app.fileURL, provisioningProfiles: profiles,
        customEntitlements: [mainID: [memory: false], helperID: [memory: true]]
    )
    let helper = app.appExtensions.first!
    expect(app.entitlements[memory] as? Bool, false, "main app choice")
    expect(helper.entitlements[memory] as? Bool, true, "extension choice")

    let installed = InstalledApp(directoryURL: root.appendingPathComponent("Metadata"))
    let operation = MetadataOperation()
    try operation.cacheEntitlements(for: installed, targetAppBundle: app)
    let directory = installed.directoryURL.appendingPathComponent("Entitlements")
    let main = try Data(contentsOf: directory.appendingPathComponent(mainID + ".plist"))
    let ext = try Data(contentsOf: directory.appendingPathComponent(helperID + ".plist"))
    let mainValues = try PropertyListSerialization.propertyList(from: main, format: nil) as! [String: any Sendable]
    let extValues = try PropertyListSerialization.propertyList(from: ext, format: nil) as! [String: any Sendable]
    expect(mainValues[memory] as? Bool, false, "main signature cached independently of profile")
    expect(extValues[memory] as? Bool, true, "extension signature cached independently of profile")
}

func repeatedRefresh(_ root: URL) async throws {
    let (app, profiles) = try fixture(at: root, original: ["get-task-allow": true])
    let signer = AppBundleSigner(team: Team(), keyStore: KeyStore())
    let installed = InstalledApp(directoryURL: root.appendingPathComponent("Metadata"))
    installed.customEntitlements = [memory: true]
    let routing = RoutingOperation()
    routing.context.installedApp = installed
    let cache = MetadataOperation()
    for round in 1...5 {
        let request = routing.requestedEntitlements(for: app, identifier: "com.example.vm", resignedIdentifier: mainID)!
        try await signer.signApp(
            at: app.fileURL, provisioningProfiles: profiles, customEntitlements: [mainID: request]
        )
        try cache.cacheEntitlements(for: installed, targetAppBundle: app)
        let url = installed.directoryURL.appendingPathComponent("Entitlements/" + mainID + ".plist")
        let data = try Data(contentsOf: url)
        installed.customEntitlements = try PropertyListSerialization.propertyList(
            from: data, format: nil
        ) as? [String: any Sendable]
        expect(installed.customEntitlements?[memory] as? Bool, true, "refresh round \(round)")
    }
}

func routingChoices(_ root: URL) throws {
    let (app, _) = try fixture(at: root, original: [:])
    let operation = RoutingOperation()
    let installed = InstalledApp(directoryURL: root)
    installed.customEntitlements = [memory: true]
    installed.appExtensions = [InstalledExtension(helperID, entitlements: [addressing: true])]
    operation.context.installedApp = installed
    operation.context.customEntitlementsByBundleID["com.example.vm"] = [memory: false]
    operation.context.additionalEntitlements[ALTEntitlement(rawValue: memory)] = false
    let main = operation.requestedEntitlements(for: app, identifier: "com.example.vm", resignedIdentifier: mainID)!
    expect(main[memory] as? Bool, false, "explicit choice overrides cached preference after rename")
    let helper = operation.requestedEntitlements(
        for: app.appExtensions.first!, identifier: helperID, resignedIdentifier: helperID
    )!
    expect(helper[memory] as? Bool, nil, "main-only additional flags do not reach extensions")
    expect(helper[addressing] as? Bool, true, "extension keeps its cached choice")
}

func rejectLostSignature(_ root: URL) async throws {
    let (app, profiles) = try fixture(at: root, original: [memory: true])
    CodeSigner.dropMemory = true
    let signer = AppBundleSigner(team: Team(), keyStore: KeyStore())
    do {
        try await signer.signApp(at: app.fileURL, provisioningProfiles: profiles, progress: nil)
        preconditionFailure("A dropped memory request was reported as successful")
    } catch SignerError.invalidApp(let cause) {
        precondition(cause.contains("did not retain"), cause)
    }
}

func rejectInvalidValues(_ root: URL) async throws {
    let (app, profiles) = try fixture(at: root, original: [:])
    let signer = AppBundleSigner(team: Team(), keyStore: KeyStore())
    let invalidValues: [any Sendable] = ["true", 1, 0]
    for value in invalidValues {
        do {
            try await signer.signApp(
                at: app.fileURL, provisioningProfiles: profiles, customEntitlements: [mainID: [memory: value]]
            )
            preconditionFailure("A non-Boolean memory request was accepted")
        } catch SignerError.invalidApp(let cause) {
            precondition(cause.contains("must be a Boolean"), cause)
        }
    }
    precondition(CodeSigner.calls == 0, "Malformed requests reached the signing backend")
}

@main
struct MemorySigningRegression {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        switch CommandLine.arguments[1] {
        case "original": try await originalPackage(root)
        case "cached": try await cachedPackage(root)
        case "disabled": try await disabledAndRemoved(root)
        case "targets": try await targetsAndCache(root)
        case "refresh": try await repeatedRefresh(root)
        case "routing": try routingChoices(root)
        case "lost": try await rejectLostSignature(root)
        case "invalid": try await rejectInvalidValues(root)
        default: preconditionFailure("Unknown scenario")
        }
        print("PASS", CommandLine.arguments[1])
    }
}
