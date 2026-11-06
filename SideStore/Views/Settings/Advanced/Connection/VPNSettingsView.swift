import SwiftUI
import UIKit

struct VPNSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(VPNAppPreferences.autoOpenKey) private var autoOpen = true
    @AppStorage(VPNAppPreferences.destinationKey) private var destination = VPNAppDestination.localDevVPN.rawValue
    @AppStorage(VPNAppPreferences.shortcutNameKey) private var shortcutName = VPNAppPreferences.defaultShortcutName
    @AppStorage(VPNAppPreferences.customURLKey) private var customURL = ""
    @State private var localDevVPNInstalled = false
    @State private var isOpening = false
    @State private var showOpenError = false

    var body: some View {
        List {
            behaviorSection
            appSection
            targetConfiguration
            testSection
        }
        .navigationTitle("VPN Auto-Open")
        .onAppear(perform: refreshInstalledApps)
        .onChange(of: scenePhase) { phase in
            if phase == .active { refreshInstalledApps() }
        }
        .alert("Could Not Open VPN App", isPresented: $showOpenError) {
            SwiftUI.Button("OK", role: .cancel) { }
        } message: {
            Text("Check that the selected app is installed and its launch URL or shortcut name is correct. You can also open the VPN app manually.")
        }
    }

    private var behaviorSection: some View {
        Section {
            Toggle("Automatically Open VPN App", isOn: $autoOpen)
        } footer: {
            Text("When a foreground operation needs the local VPN and it is not connected, open the selected app. Connect the VPN, return here, and retry. Background refresh will not open another app.")
        }
    }

    private var appSection: some View {
        Section {
            destinationRow(.localDevVPN, title: "LocalDevVPN",
                           detail: localDevVPNInstalled ? "Installed" : "Not Installed",
                           available: localDevVPNInstalled)
            destinationRow(.shortcut, title: "Other VPN App via Shortcuts", detail: "Choose an installed app in Shortcuts")
            destinationRow(.customURL, title: "Custom App URL", detail: "Use a launch URL provided by the VPN app")
            SwiftUI.Button("Refresh Installed Apps", action: refreshInstalledApps)
        } header: {
            Text("VPN App")
        } footer: {
            Text("iOS only allows detecting apps with a supported launch URL. For WireGuard, StosVPN, or other apps, use Shortcuts to choose an installed app. The VPN must support SideStore's local device connection.")
        }
    }

    private func destinationRow(_ value: VPNAppDestination, title: String, detail: String, available: Bool = true) -> some View {
        SwiftUI.Button { destination = value.rawValue } label: {
            HStack {
                destinationLabel(title: title, detail: detail)
                Spacer()
                if destination == value.rawValue { Image(systemName: "checkmark") }
            }
        }
        .disabled(!available)
        .accessibilityAddTraits(destination == value.rawValue ? .isSelected : [])
    }

    private func destinationLabel(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(NSLocalizedString(title, comment: "")).foregroundColor(.primary)
            Text(NSLocalizedString(detail, comment: "")).font(.footnote).foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var targetConfiguration: some View {
        if destination == VPNAppDestination.shortcut.rawValue { shortcutSection }
        if destination == VPNAppDestination.customURL.rawValue { customURLSection }
    }

    private var shortcutSection: some View {
        Section {
            launchTextField("Shortcut Name", text: $shortcutName)
            SwiftUI.Button("Open Shortcuts") {
                UIApplication.shared.open(URL(string: "shortcuts://")!)
            }
        } header: {
            Text("Choose Another Installed VPN App")
        } footer: {
            Text("In Shortcuts, create a shortcut, add the Open App action, and select your VPN app from the system app list. Enter that shortcut's exact name here. You can also use a shortcut that connects your local VPN.")
        }
    }

    private var customURLSection: some View {
        Section {
            launchTextField("App Launch URL", text: $customURL)
        } footer: {
            Text("Enter the VPN app's documented URL, for example localdevvpn://. Web links are not supported. Use the button below to test the URL.")
        }
    }

    private func launchTextField(_ title: LocalizedStringKey, text: Binding<String>) -> some View {
        TextField(title, text: text)
            #if !os(tvOS)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            #endif
    }

    private var testSection: some View {
        Section {
            SwiftUI.Button("Open Selected VPN App") { Task { await openSelectedApp() } }
                .disabled(isOpening || !canTestSelection)
        } footer: {
            Text("Opening an app does not confirm that its VPN is connected. Enable the VPN in that app before retrying your operation.")
        }
    }

    private var canTestSelection: Bool {
        switch VPNAppDestination(rawValue: destination) {
        case .localDevVPN: return localDevVPNInstalled
        case .shortcut: return !shortcutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .customURL: return VPNAppPreferences.customLaunchURL(customURL) != nil
        case nil: return false
        }
    }

    private func refreshInstalledApps() {
        localDevVPNInstalled = UIApplication.shared.canOpenURL(VPNAppPreferences.localDevVPNURL)
    }

    @MainActor
    private func openSelectedApp() async {
        isOpening = true
        defer { isOpening = false }
        showOpenError = !(await VPNAppManager.openSelectedApp())
    }
}
