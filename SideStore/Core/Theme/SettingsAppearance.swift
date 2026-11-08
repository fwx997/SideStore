import SwiftUI
import UIKit

// zh-patch: Scope navigation colors to each page, including pushed SwiftUI destinations.
enum SettingsPageStyle {
    case system
    case branded

    @MainActor
    func apply(to item: UINavigationItem, tintColor: UIColor) {
        #if !os(tvOS)
        let appearance = UINavigationBarAppearance()
        let foreground: UIColor
        switch self {
        case .system:
            appearance.configureWithDefaultBackground()
            foreground = .label
            appearance.configureWithTintColor(tintColor)
        case .branded:
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = .settingsBackground
            foreground = .white
            appearance.configureWithTintColor(.white)
        }
        appearance.titleTextAttributes = [.foregroundColor: foreground]
        appearance.largeTitleTextAttributes = [.foregroundColor: foreground]
        item.standardAppearance = appearance
        item.scrollEdgeAppearance = appearance
        item.compactAppearance = appearance
        item.compactScrollEdgeAppearance = appearance
        #endif
    }
}

extension View {
    func themeAccent() -> some View {
        modifier(ThemeAccentModifier())
    }

    func settingsAppearance(_ style: SettingsPageStyle = .system) -> some View {
        modifier(SettingsAppearanceModifier(style: style))
    }
}

private struct ThemeAccentModifier: ViewModifier {
    @ObservedObject private var themeManager = ThemeManager.shared

    func body(content: Content) -> some View {
        content
            .tint(Color(uiColor: themeManager.primaryColor))
            .accentColor(Color(uiColor: themeManager.primaryColor))
    }
}

private struct SettingsAppearanceModifier: ViewModifier {
    let style: SettingsPageStyle
    @ObservedObject private var themeManager = ThemeManager.shared

    func body(content: Content) -> some View {
        content
            .themeAccent()
            #if !os(tvOS)
            .background(SettingsNavigationAppearance(style: style, tintColor: themeManager.primaryColor)
                .frame(width: 0, height: 0))
            #endif
    }
}

#if !os(tvOS)
private struct SettingsNavigationAppearance: UIViewControllerRepresentable {
    let style: SettingsPageStyle
    let tintColor: UIColor

    func makeUIViewController(context: Context) -> AppearanceController {
        AppearanceController(style: style, tintColor: tintColor)
    }

    func updateUIViewController(_ controller: AppearanceController, context: Context) {
        controller.style = style
        controller.themeColor = tintColor
        controller.applyAppearance()
    }

    final class AppearanceController: UIViewController {
        var style: SettingsPageStyle
        var themeColor: UIColor

        init(style: SettingsPageStyle, tintColor: UIColor) {
            self.style = style
            self.themeColor = tintColor
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            applyAppearance()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            applyAppearance()
        }

        func applyAppearance() {
            // Embedded navigation transitions still need real-device verification.
            var target = parent
            while let ancestor = target?.parent, !(ancestor is UINavigationController) {
                target = ancestor
            }
            guard let target, target.parent is UINavigationController else { return }
            // Keep the owning navigation item intact when another page is pushed or popped.
            style.apply(to: target.navigationItem, tintColor: themeColor)
        }
    }
}
#endif
