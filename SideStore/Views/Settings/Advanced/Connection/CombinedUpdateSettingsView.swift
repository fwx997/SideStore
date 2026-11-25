import SwiftUI

struct CombinedUpdateSettingsView: View {
    @State private var address = CombinedUpdateSourceSettings.currentURL?.absoluteString ?? ""
    @State private var isSaving = false
    @State private var message: String?

    var body: some View {
        List {
            Section {
                TextField("Update Address", text: $address)
                    #if !os(tvOS)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
                    #endif
            } header: {
                Text("Update Address")
            } footer: {
                Text("Use an HTTPS source.json address or its directory. This address controls checks and downloads for the combined app. Other app sources are unchanged.")
            }
            Section {
                SwiftUI.Button("Save and Check for Updates") { Task { await save() } }
                    .disabled(isSaving || CombinedUpdateSourceSettings.normalize(address) == nil)
                SwiftUI.Button("Restore Default Address") {
                    address = CombinedUpdateSourceSettings.defaultURL?.absoluteString ?? ""
                }
                .disabled(isSaving)
            }
            if isSaving { ProgressView("Checking for Updates…") }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle("Combined App Updates")
        .settingsAppearance()
    }

    @MainActor
    private func save() async {
        isSaving = true
        message = nil
        defer { isSaving = false }
        do {
            try await CombinedUpdateSourceSettings.save(address)
            address = CombinedUpdateSourceSettings.currentURL?.absoluteString ?? address
            _ = try await AppManager.shared.fetchSources()
            message = NSLocalizedString("Update address saved and checked.", comment: "")
        } catch {
            message = error.localizedDescription
        }
    }
}
