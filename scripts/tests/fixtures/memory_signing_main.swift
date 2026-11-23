import Foundation
import CoreFoundation

private let memory = "com.apple.developer.kernel.increased-memory-limit"
private let addressing = "com.apple.developer.kernel.extended-virtual-addressing"
private let mainID = "com.example.vm.TESTTEAM"
private let helperID = mainID + ".Helper"

func expect(_ actual: Bool?, _ expected: Bool?, _ label: String) {
    precondition(actual == expected, "\(label): expected \(String(describing: expected)), got \(String(describing: actual))")
}

func fixture(
    at root: URL,
    original: [String: any Sendable],
    memoryGrant: Bool? = true,
    helperMemoryGrant: Bool? = true
) throws -> (AppBundle, [ProvisioningProfile]) {
    let appURL = root.appendingPathComponent("Test.app")
    let helperURL = appURL.appendingPathComponent("PlugIns/Helper.appex")
    try FileManager.default.createDirectory(at: helperURL, withIntermediateDirectories: true)
    try writePlist(["CFBundleIdentifier": mainID], to: appURL.appendingPathComponent("Info.plist"))
    try writePlist(["CFBundleIdentifier": helperID], to: helperURL.appendingPathComponent("Info.plist"))
    try writePlist(original, to: appURL.appendingPathComponent("Signature.plist"))
    try writePlist(["get-task-allow": true], to: helperURL.appendingPathComponent("Signature.plist"))
    let profiles = [mainID, helperID].map { identifier in
        var entitlements: [String: any Sendable] = [
            "application-identifier": "TESTTEAM." + identifier, "get-task-allow": true
        ]
        if let grant = identifier == mainID ? memoryGrant : helperMemoryGrant {
            entitlements[memory] = grant
        }
        return ProvisioningProfile(
            name: "Test profile",
            bundleIdentifier: identifier,
            teamIdentifier: "TESTTEAM",
            entitlements: entitlements,
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
    expect(app.entitlements[addressing] as? Bool, nil, "address-space request still requires its profile entitlement")
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
    expect(app.entitlements[addressing] as? Bool, nil, "unsupported address-space key remains absent")
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
    routing.context.additionalEntitlements = OperationEntitlements.defaultAdditionalEntitlements
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
    operation.context.additionalEntitlements = OperationEntitlements.defaultAdditionalEntitlements
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
    let invalidValues: [any Sendable] = ["true", 1, 0, 1.0, ALTEntitlement.increasedMemoryLimit]
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

func defaultInstallation(_ root: URL) async throws {
    let defaults = OperationEntitlements.defaultAdditionalEntitlements
    precondition(!defaults.isEmpty, "The real installation defaults must be exercised")
    for (_, value) in defaults {
        let number = value as! NSNumber
        precondition(CFGetTypeID(number) == CFBooleanGetTypeID(), "A default request is not a Boolean")
    }
    for grant in [nil, false, true] as [Bool?] {
        let (app, profiles) = try fixture(at: root, original: [:], memoryGrant: grant)
        let routing = RoutingOperation()
        routing.context.additionalEntitlements = defaults
        let request = routing.requestedEntitlements(for: app, identifier: mainID, resignedIdentifier: mainID)!
        try await AppBundleSigner(team: Team(), keyStore: KeyStore()).signApp(
            at: app.fileURL, provisioningProfiles: profiles, customEntitlements: [mainID: request]
        )
        expect(app.entitlements[memory] as? Bool, grant == true ? true : nil, "default install respects the profile")
        expect(app.appExtensions.first!.entitlements[memory] as? Bool, nil, "default install isolates extensions")
    }
}

func defaultChoices(_ root: URL) async throws {
    let (app, profiles) = try fixture(at: root, original: [memory: true])
    let signer = AppBundleSigner(team: Team(), keyStore: KeyStore())
    let installed = InstalledApp(directoryURL: root)
    installed.customEntitlements = [memory: true]
    let routing = RoutingOperation()
    routing.context.installedApp = installed
    routing.context.additionalEntitlements = OperationEntitlements.defaultAdditionalEntitlements
    for choice in [false, nil] as [Bool?] {
        let selected: [String: any Sendable] = choice.map { [memory: $0] } ?? [:]
        routing.context.customEntitlementsByBundleID[mainID] = selected
        let request = routing.requestedEntitlements(for: app, identifier: mainID, resignedIdentifier: mainID)!
        try await signer.signApp(at: app.fileURL, provisioningProfiles: profiles, customEntitlements: [mainID: request])
        expect(app.entitlements[memory] as? Bool, choice, "explicit choice survives automatic defaults")
        routing.context.customEntitlementsByBundleID = [:]
        installed.customEntitlements = selected
        let cached = routing.requestedEntitlements(for: app, identifier: mainID, resignedIdentifier: mainID)!
        expect(cached[memory] as? Bool, choice, "cached choice survives automatic defaults")
    }
    routing.context.installedApp = nil
    try writePlist([memory: false], to: app.fileURL.appendingPathComponent("Signature.plist"))
    let original = routing.requestedEntitlements(for: app, identifier: mainID, resignedIdentifier: mainID)!
    expect(original[memory] as? Bool, false, "original false survives automatic defaults")
}

func profileBoundary(_ root: URL) async throws {
    let signer = AppBundleSigner(team: Team(), keyStore: KeyStore())
    for grant in [nil, false, true] as [Bool?] {
        let helperGrant: Bool? = grant == true ? nil : true
        let (app, profiles) = try fixture(
            at: root, original: [memory: true], memoryGrant: grant, helperMemoryGrant: helperGrant
        )
        try await signer.signApp(
            at: app.fileURL, provisioningProfiles: profiles,
            customEntitlements: [mainID: [memory: true], helperID: [memory: true]]
        )
        expect(app.entitlements[memory] as? Bool, grant == true ? true : nil, "main profile boundary")
        expect(app.appExtensions.first!.entitlements[memory] as? Bool, helperGrant, "helper profile boundary")
    }
    let (app, profiles) = try fixture(at: root, original: [memory: true], memoryGrant: nil)
    let legacy: any CodeSignerAPI = signer
    try await legacy.signApp(at: app.fileURL, provisioningProfiles: profiles, progress: nil)
    expect(app.entitlements[memory] as? Bool, nil, "legacy API also filters unapproved memory")
}

func revokedGrant(_ root: URL) async throws {
    let (app, profiles) = try fixture(at: root, original: [memory: true], memoryGrant: nil)
    let installed = InstalledApp(directoryURL: root.appendingPathComponent("Metadata"))
    installed.customEntitlements = [memory: true]
    let routing = RoutingOperation()
    routing.context.installedApp = installed
    routing.context.additionalEntitlements = OperationEntitlements.defaultAdditionalEntitlements
    let request = routing.requestedEntitlements(for: app, identifier: mainID, resignedIdentifier: mainID)!
    try await AppBundleSigner(team: Team(), keyStore: KeyStore()).signApp(
        at: app.fileURL, provisioningProfiles: profiles, customEntitlements: [mainID: request]
    )
    try MetadataOperation().cacheEntitlements(for: installed, targetAppBundle: app)
    let data = try Data(contentsOf: installed.directoryURL.appendingPathComponent("Entitlements/" + mainID + ".plist"))
    installed.customEntitlements = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: any Sendable]
    expect(installed.customEntitlements?[memory] as? Bool, nil, "cache contains no unapproved request")
    let refreshed = routing.requestedEntitlements(for: app, identifier: mainID, resignedIdentifier: mainID)!
    expect(refreshed[memory] as? Bool, nil, "defaults do not revive a filtered cached request")
}

func rejectInjectedSignature(_ root: URL) async throws {
    let (app, profiles) = try fixture(at: root, original: [memory: true], memoryGrant: nil)
    CodeSigner.injectMemory = true
    do {
        try await AppBundleSigner(team: Team(), keyStore: KeyStore()).signApp(
            at: app.fileURL, provisioningProfiles: profiles, progress: nil
        )
        preconditionFailure("An unapproved memory request was reported as successful")
    } catch SignerError.invalidApp(let cause) {
        precondition(cause.contains("profile-authorized"), cause)
    }
}

func profileFeatures(_ root: URL) async throws {
    let (app, _) = try fixture(at: root, original: [:])
    let operation = FeatureOperation()
    operation.context.additionalEntitlements = OperationEntitlements.defaultAdditionalEntitlements
    let initial = ALTAppID(bundleIdentifier: mainID, features: [.appGroups: "true"])
    let paid = try await operation.updateFeatures(for: initial, targetAppBundle: app, team: Team(type: .paid))
    precondition(paid.features[.increasedMemoryLimit] == "true", "An allowed memory capability was not requested")
    let free = try await operation.updateFeatures(for: initial, targetAppBundle: app, team: Team(type: .free))
    precondition(free.features[.increasedMemoryLimit] == "true", "The free team did not request its memory capability")
    precondition(free.features[.extendedVirtualAddressing] == nil, "Extended addressing was enabled for a free team")
    let helper = try await operation.updateFeatures(for: initial, targetAppBundle: app.appExtensions.first!, team: Team(type: .paid))
    precondition(helper.features[.increasedMemoryLimit] == nil, "Main-app defaults leaked into helper provisioning")
    operation.context.customEntitlementsByBundleID[mainID] = [memory: false]
    let disabled = try await operation.updateFeatures(for: paid, targetAppBundle: app, team: Team(type: .paid))
    precondition(disabled.features[.increasedMemoryLimit] == "false", "Defaults re-enabled an explicit disabled capability")
}

func cachedProfileFeatures(_ root: URL) async throws {
    let (app, _) = try fixture(at: root, original: [memory: true])
    let operation = FeatureOperation()
    operation.context.additionalEntitlements = OperationEntitlements.defaultAdditionalEntitlements
    let installed = InstalledApp(directoryURL: root.appendingPathComponent("cache"))
    operation.context.installedApp = installed
    let initial = ALTAppID(bundleIdentifier: mainID, features: [.appGroups: "true"])
    let cachedChoices: [[String: any Sendable]] = [[memory: false], [:], [memory: true]]
    for cached in cachedChoices {
        await DeveloperPortalProxy.shared.reset()
        installed.customEntitlements = cached
        let updated = try await operation.updateFeatures(for: initial, targetAppBundle: app, team: Team())
        let enabled = cached[memory] as? Bool == true
        precondition((updated.features[.increasedMemoryLimit] == "true") == enabled,
                     "The effective portal capability disagrees with the cached signing choice")
        let requests = await DeveloperPortalProxy.shared.updates
        precondition(requests.count == (enabled ? 1 : 0),
                     "An off or absent cached choice must not issue a redundant update to an already-off capability")
        if enabled {
            precondition(requests[0].features[.increasedMemoryLimit] == "true",
                         "The requested profile must explicitly reassert the cached memory grant")
        }
    }
    installed.customEntitlements = [memory: false]
    await DeveloperPortalProxy.shared.reset()
    let enabledOnPortal = ALTAppID(bundleIdentifier: mainID, features: [.appGroups: "true", .increasedMemoryLimit: "true"])
    let disabled = try await operation.updateFeatures(for: enabledOnPortal, targetAppBundle: app, team: Team())
    let disabledRequests = await DeveloperPortalProxy.shared.updates
    precondition(disabled.features[.increasedMemoryLimit] == "false"
                 && disabledRequests.count == 1
                 && disabledRequests[0].features[.increasedMemoryLimit] == "false",
                 "An explicit disabled choice must update a previously enabled portal capability")
    let helper = app.appExtensions.first!
    installed.appExtensions = [InstalledExtension(helperID, entitlements: [memory: true])]
    let helperAppID = ALTAppID(bundleIdentifier: helperID, features: [.appGroups: "true"])
    let enabled = try await operation.updateFeatures(for: helperAppID, targetAppBundle: helper, team: Team())
    precondition(enabled.features[.increasedMemoryLimit] == "true", "The extension's own cached request was lost")
    operation.context.customEntitlementsByBundleID[mainID] = [:]
    let removed = try await operation.updateFeatures(for: initial, targetAppBundle: app, team: Team())
    precondition(removed.features[.increasedMemoryLimit] == nil, "An explicit deletion was not preserved")
    operation.context.targetBundleIdentifier = "com.example.renamed"
    operation.context.customEntitlementsByBundleID["com.example.renamed"] = [memory: true]
    let renamed = try await operation.updateFeatures(for: initial, targetAppBundle: app, team: Team())
    precondition(renamed.features[.increasedMemoryLimit] == "true", "An explicit choice under a custom main ID was lost")
}

func refreshProfileGrants(_ root: URL) throws {
    let (app, profiles) = try fixture(at: root, original: [memory: true])
    let operation = RefreshOperation()
    let installed = InstalledApp(directoryURL: root)
    installed.customEntitlements = [memory: true]
    operation.context.installedApp = installed
    var grants = Dictionary(uniqueKeysWithValues: profiles.map { ($0.bundleIdentifier, $0) })
    try operation.validateMemoryGrants(profiles: grants, appBundle: app)
    let invalidGrants: [(any Sendable)?] = [nil, false, 1, "true"]
    for grant in invalidGrants {
        var entitlements: [String: any Sendable] = [:]
        if let grant { entitlements[memory] = grant }
        grants[mainID] = ProvisioningProfile(name: "Missing grant", bundleIdentifier: mainID,
            teamIdentifier: "TESTTEAM", entitlements: entitlements, data: Data())
        do {
            try operation.validateMemoryGrants(profiles: grants, appBundle: app)
            preconditionFailure("A profile-only refresh accepted an absent or invalid memory grant")
        } catch OperationError.invalidApp(let reason) {
            precondition(reason.contains("Refresh stopped"), reason)
        }
    }
    grants[mainID] = profiles[0]
    installed.appExtensions = [InstalledExtension(helperID, entitlements: [memory: true])]
    grants.removeValue(forKey: helperID)
    do {
        try operation.validateMemoryGrants(profiles: grants, appBundle: app)
        preconditionFailure("The main app's grant was incorrectly used for its helper")
    } catch OperationError.invalidApp(let reason) {
        precondition(reason.contains(helperID), reason)
    }
    operation.context.useMainProfile = true
    try operation.validateMemoryGrants(profiles: grants, appBundle: app)
    installed.customEntitlements = [:]
    installed.appExtensions = []
    try operation.validateMemoryGrants(profiles: [:], appBundle: app)
}

func refreshInjectionBoundary(_ root: URL) async throws {
    let (app, profiles) = try fixture(at: root, original: [memory: true])
    let grants = Dictionary(uniqueKeysWithValues: profiles.map { ($0.bundleIdentifier, $0) })
    for batched in [false, true] {
        let operation = RefreshOperation()
        let installed = InstalledApp(directoryURL: root)
        installed.customEntitlements = [memory: true]
        operation.context.installedApp = installed
        operation.context.targetAppBundle = app
        operation.context.provisioningProfiles = [:]
        operation.context.isCellularRefreshGroup = batched
        await ProfileInjectionRecorder.shared.reset()
        do {
            _ = try await operation.execute(parentProgress: nil)
            preconditionFailure("A refresh with no memory grant reached injection")
        } catch OperationError.invalidApp {}
        let rejectedCount = await ProfileInjectionRecorder.shared.count
        precondition(rejectedCount == 0 && operation.context.sharedContext.pending.isEmpty)
        precondition(operation.updates == 0, "Rejected refresh changed the installed metadata")

        operation.context.provisioningProfiles = grants
        _ = try await operation.execute(parentProgress: nil)
        let acceptedCount = await ProfileInjectionRecorder.shared.count
        precondition(acceptedCount == (batched ? 0 : grants.count))
        precondition(operation.context.sharedContext.pending.count == (batched ? 1 : 0))
        precondition(operation.updates == (batched ? 0 : 1))
    }
}

func toolMemoryRequest(_ root: URL) async throws {
    let suite = "memory-request-test." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = MemoryCapabilityRequestStore(defaults: defaults)
    let (app, profiles) = try fixture(at: root, original: [:])
    let installed = InstalledApp(directoryURL: root.appendingPathComponent("cache"))
    installed.customEntitlements = [:]
    store.recordEnabledCapabilityRequests(for: mainID, capabilities: ["EXTENDED_VIRTUAL_ADDRESSING"])
    precondition(store.request(for: mainID) == nil)
    store.recordEnabledCapabilityRequests(for: mainID, capabilities: ["INCREASED_MEMORY_LIMIT"])
    let selection = OperationEntitlements.requested(
        for: app, identifiers: ["com.example.vm", mainID], resignedBundleIdentifier: mainID,
        custom: [:], installedApp: installed,
        additional: OperationEntitlements.defaultAdditionalEntitlements, requestStore: store
    )
    precondition(selection.pendingMemoryRequest != nil)
    expect(selection.values?[memory] as? Bool, true, "Tool request upgrades a stripped .42 cache")
    expect(installed.customEntitlements?[memory] as? Bool, nil, "Request must not change the actual-signature cache")
    expect(app.entitlements[memory] as? Bool, nil, "Request must not claim that the old binary changed")
    let displayed = OperationEntitlements.preparingCustomization([:], resignedBundleIdentifier: mainID, requestStore: store)
    expect(displayed[memory] as? Bool, true, "The customization page must show the pending request")

    let helper = app.appExtensions.first!
    let helperSelection = OperationEntitlements.requested(
        for: helper, identifiers: [helperID], resignedBundleIdentifier: helperID,
        custom: [:], installedApp: installed, additional: [:], requestStore: store
    )
    precondition(helperSelection.pendingMemoryRequest == nil, "The main request leaked into an extension")
    let anotherTeam = OperationEntitlements.requested(
        for: app, identifiers: [mainID, "com.example.vm.OTHERTEAM"], resignedBundleIdentifier: "com.example.vm.OTHERTEAM",
        custom: [:], installedApp: installed, additional: [:], requestStore: store
    )
    precondition(anotherTeam.pendingMemoryRequest == nil, "A tool request crossed signing teams")

    try await AppBundleSigner(team: Team(), keyStore: KeyStore()).signApp(
        at: app.fileURL, provisioningProfiles: profiles, customEntitlements: [mainID: selection.values!]
    )
    try MetadataOperation().cacheEntitlements(
        for: installed, targetAppBundle: app,
        pendingRequests: [mainID: selection.pendingMemoryRequest!], requestStore: store
    )
    expect(app.entitlements[memory] as? Bool, true, "The requested entitlement reached the binary")
    precondition(store.request(for: mainID) == nil, "Completed signing did not consume the applied request")
}

func toolMemoryChoices(_ root: URL) throws {
    let suite = "memory-choice-test." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = MemoryCapabilityRequestStore(defaults: defaults)
    let (app, _) = try fixture(at: root, original: [:])
    let installed = InstalledApp(directoryURL: root)
    installed.customEntitlements = [:]
    for choice in [[memory: false], [:]] as [[String: any Sendable]] {
        store.recordEnabledCapabilityRequests(for: mainID, capabilities: ["INCREASED_MEMORY_LIMIT"])
        let selected = OperationEntitlements.requested(
            for: app, identifiers: [mainID], resignedBundleIdentifier: mainID,
            custom: [mainID: choice], explicitMemorySelections: [mainID], installedApp: installed,
            additional: OperationEntitlements.defaultAdditionalEntitlements, requestStore: store
        )
        precondition(selected.pendingMemoryRequest == nil && store.request(for: mainID) == nil)
        expect(selected.values?[memory] as? Bool, choice[memory] as? Bool, "The later user choice must win")
    }
    store.recordEnabledCapabilityRequests(for: mainID, capabilities: ["INCREASED_MEMORY_LIMIT"])
    let loadedCache = OperationEntitlements.requested(
        for: app, identifiers: [mainID], resignedBundleIdentifier: mainID,
        custom: [mainID: [:]], explicitMemorySelections: [], installedApp: installed,
        additional: [:], requestStore: store
    )
    expect(loadedCache.values?[memory] as? Bool, true, "Loading the old cache is not an explicit user deletion")
    precondition(store.request(for: mainID) != nil)
    let invalid = OperationEntitlements.requested(
        for: app, identifiers: [mainID], resignedBundleIdentifier: mainID,
        custom: [mainID: [memory: "false"]], explicitMemorySelections: [mainID], installedApp: installed,
        additional: [:], requestStore: store
    )
    precondition(invalid.values?[memory] as? String == "false")
    precondition(store.request(for: mainID) != nil, "An invalid typed value was treated as a valid deletion")
}

func toolMemoryConsumption(_ root: URL) throws {
    let suite = "memory-consumption-test." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = MemoryCapabilityRequestStore(defaults: defaults)
    let (app, _) = try fixture(at: root, original: [:])
    let installed = InstalledApp(directoryURL: root.appendingPathComponent("cache"))
    store.recordEnabledCapabilityRequests(for: mainID, capabilities: ["INCREASED_MEMORY_LIMIT"])
    let first = store.request(for: mainID)!
    let metadata = MetadataOperation()
    try metadata.cacheEntitlements(for: installed, targetAppBundle: app,
                                   pendingRequests: [mainID: first], requestStore: store)
    precondition(store.request(for: mainID) == first, "An ungranted request was consumed")
    try writePlist([memory: true], to: app.fileURL.appendingPathComponent("Signature.plist"))
    try metadata.cacheEntitlements(for: installed, targetAppBundle: app, requestStore: store)
    precondition(store.request(for: mainID) == first, "A refresh without a signing receipt consumed the request")

    let brokenCache = root.appendingPathComponent("not-a-directory")
    try Data("cache write failure".utf8).write(to: brokenCache)
    do {
        try metadata.cacheEntitlements(for: InstalledApp(directoryURL: brokenCache), targetAppBundle: app,
                                       pendingRequests: [mainID: first], requestStore: store)
        preconditionFailure("The invalid cache path unexpectedly succeeded")
    } catch {}
    precondition(store.request(for: mainID) == first, "A failed cache write consumed the request")

    store.recordEnabledCapabilityRequests(for: mainID, capabilities: ["INCREASED_MEMORY_LIMIT"])
    let second = store.request(for: mainID)!
    precondition(first != second)
    try metadata.cacheEntitlements(for: installed, targetAppBundle: app,
                                   pendingRequests: [mainID: first], requestStore: store)
    precondition(store.request(for: mainID) == second, "An older operation consumed a newer request")
    try metadata.cacheEntitlements(for: installed, targetAppBundle: app,
                                   pendingRequests: [mainID: second], requestStore: store)
    precondition(store.request(for: mainID) == nil)
}

func signingMemoryGrants() throws {
    let request = MemoryCapabilityRequestStore.Request(bundleIdentifier: mainID, revision: "test-revision")
    let required: [([String: any Sendable]?, MemoryCapabilityRequestStore.Request?)] = [
        (nil, request), ([memory: true], nil)
    ]
    for (cached, pending) in required {
        do {
            try OperationEntitlements.validateSigningMemoryGrant(
                requested: [memory: true], cached: cached, pendingRequest: pending, profile: [:], bundleIdentifier: mainID
            )
            preconditionFailure("Reinstall would silently remove a requested or existing memory grant")
        } catch OperationError.invalidApp(let reason) {
            precondition(reason.contains("Reinstall stopped"))
        }
        try OperationEntitlements.validateSigningMemoryGrant(
            requested: [memory: true], cached: cached, pendingRequest: pending, profile: [memory: true], bundleIdentifier: mainID
        )
    }
    try OperationEntitlements.validateSigningMemoryGrant(
        requested: [memory: true], cached: nil, pendingRequest: nil, profile: [:], bundleIdentifier: mainID
    )
    for disabled in [[memory: false], [:]] as [[String: any Sendable]] {
        try OperationEntitlements.validateSigningMemoryGrant(
            requested: disabled, cached: [memory: true], pendingRequest: nil, profile: [:], bundleIdentifier: mainID
        )
    }
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
        case "defaults": try await defaultInstallation(root)
        case "default-choices": try await defaultChoices(root)
        case "profile-boundary": try await profileBoundary(root)
        case "revoked-grant": try await revokedGrant(root)
        case "injected": try await rejectInjectedSignature(root)
        case "features": try await profileFeatures(root)
        case "cached-features": try await cachedProfileFeatures(root)
        case "refresh-grants": try refreshProfileGrants(root)
        case "refresh-injection": try await refreshInjectionBoundary(root)
        case "tool-request": try await toolMemoryRequest(root)
        case "tool-choices": try toolMemoryChoices(root)
        case "tool-consume": try toolMemoryConsumption(root)
        case "signing-grants": try signingMemoryGrants()
        default: preconditionFailure("Unknown scenario")
        }
        print("PASS", CommandLine.arguments[1])
    }
}
