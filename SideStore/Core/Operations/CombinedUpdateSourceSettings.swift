import Foundation

enum CombinedUpdateSourceSettings {
    static let addressKey = "LCCombinedUpdateSourceURL"

    static var defaultURL: URL? {
        let host = CombinedAppDistribution.hostURL(for: Bundle.Info.activeBundleURL)
        let address = (try? CombinedAppDistribution.info(at: host)[CombinedAppDistribution.sourceURLKey]) as? String
        return address.flatMap(normalize)
    }

    static var currentURL: URL? {
        UserDefaults.standard.string(forKey: addressKey).flatMap(normalize) ?? defaultURL
    }

    static func normalize(_ address: String) -> URL? {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.fragment == nil else { return nil }
        return url.pathExtension.lowercased() == "json" ? url : url.appendingPathComponent("source.json")
    }

    static func save(_ address: String) async throws {
        guard let url = normalize(address) else {
            throw NSError(domain: "CombinedUpdateSource", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Enter a valid HTTPS update address.", comment: "")])
        }
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        try await context.perform {
            guard let store = InstalledApp.fetchAltStore(in: context)?.storeApp, let current = store.source else {
                throw NSError(domain: "CombinedUpdateSource", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("The combined update source is not ready. Reopen SideStore and try again.", comment: "")])
            }
            let identifier = try Source.sourceID(from: url)
            let existing = Source.first(satisfying: NSPredicate(format: "%K == %@", #keyPath(Source.identifier), identifier), in: context)
            let selected = existing ?? current
            try selected.setSourceURL(url)
            store.source = selected
            store.sourceIdentifier = selected.identifier
            try context.save()
        }
        UserDefaults.standard.set(url.absoluteString, forKey: addressKey)
    }
}
