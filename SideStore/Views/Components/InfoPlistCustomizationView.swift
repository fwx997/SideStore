//
//  InfoPlistCustomizationView.swift
//  SideStore
//
//  Created by Magesh K on 13/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import SwiftUI
import UIKit

public struct InfoPlistCustomizationView: View {
    public typealias RawPlistType = InfoPlistCustomizationCoreView.RawPlistType
    public typealias RawPlistEntry = InfoPlistCustomizationCoreView.RawPlistEntry

    public let initialPlist: [String: Any]
    public let initialBundleID: String
    public let appendTeamID: Bool
    public let installedAppIdentities: [String: String]
    public let teamID: String
    public let onProceed: ([String: Any], Bool) -> Void
    public let onCancel: () -> Void

    public init(
        initialPlist: [String: Any],
        initialBundleID: String,
        appendTeamID: Bool = true,
        installedAppIdentities: [String: String] = [:],
        teamID: String = "",
        onProceed: @escaping ([String: Any], Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.initialPlist = initialPlist
        self.initialBundleID = initialBundleID
        self.appendTeamID = appendTeamID
        self.installedAppIdentities = installedAppIdentities
        self.teamID = teamID
        self.onProceed = onProceed
        self.onCancel = onCancel
    }

    public var body: some View {
        InfoPlistCustomizationCoreView(
            style: .dialog,
            initialPlist: initialPlist,
            initialBundleID: initialBundleID,
            appendTeamID: appendTeamID,
            installedAppIdentities: installedAppIdentities,
            teamID: teamID,
            onProceed: onProceed,
            onCancel: onCancel
        )
    }
}

extension InfoPlistCustomizationView {
    @MainActor
    public static func present(
        from presenter: UIViewController,
        initialPlist: [String: Any],
        initialBundleID: String,
        appendTeamID: Bool = true,
        installedAppIdentities: [String: String] = [:],
        teamID: String = ""
    ) async -> (modifiedPlist: [String: Any], appendTeamID: Bool)? {
        await withCheckedContinuation { continuation in
            var hostingController: UIHostingController<AnyView>?

            let view = InfoPlistCustomizationView(
                initialPlist: initialPlist,
                initialBundleID: initialBundleID,
                appendTeamID: appendTeamID,
                installedAppIdentities: installedAppIdentities,
                teamID: teamID,
                onProceed: { modifiedPlist, shouldAppend in
                    hostingController?.dismiss(animated: true) {
                        continuation.resume(returning: (modifiedPlist, shouldAppend))
                    }
                },
                onCancel: {
                    hostingController?.dismiss(animated: true) {
                        continuation.resume(returning: nil)
                    }
                }
            )

            let controller = UIHostingController(rootView: AnyView(view))
            controller.modalPresentationStyle = .overFullScreen
            controller.modalTransitionStyle = .crossDissolve
            controller.view.backgroundColor = .clear
            hostingController = controller

            presenter.present(controller, animated: true)
        }
    }
}
