//
//  CellularRefreshManager.swift
//  SideStore
//
//  Created by Magesh K on 4/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import UIKit
import Minimuxer
import Network

public final class CellularRefreshManager: @unchecked Sendable {
    public static let shared = CellularRefreshManager()

    private static let pendingRestoreKey = "zh.cellularRefresh.pendingRestoreID"
    private var coordinator: CellularRefreshCoordinator!

    private init() {
        coordinator = CellularRefreshCoordinator(environment: .init(
            shouldPause: { [unowned self] in
                guard self.isSupported && self.isEnabled else { return false }
                return await CellularPathProbe.isAvailable(.wifi) != true
            },
            cellularAvailable: { await CellularPathProbe.isAvailable(.cellular) },
            isForeground: { await Self.isAppForeground() },
            openURL: { url in await Self.openShortcut(url) },
            endpointReady: {
                await minimuxer.network.refreshEndpoint()
                if case .success(true) = await minimuxer.core.isReady(withNetworkCheck: false) { return true }
                return false
            },
            pendingID: { UserDefaults.standard.string(forKey: Self.pendingRestoreKey) },
            savePendingID: { UserDefaults.standard.set($0, forKey: Self.pendingRestoreKey) },
            settings: { [unowned self] in self.shortcutSettings }
        ))
    }

    public var isSupported: Bool {
        #if os(tvOS)
        return false
        #else
        return true
        #endif
    }

    public var isEnabled: Bool {
        return UserDefaults.standard.isCellularRefreshEnabled
    }

    public var isCellularMode: Bool {
        guard isSupported && isEnabled else { return false }
        return !minimuxer.network.isWifiSatisfied
    }

    public func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.isCellularRefreshEnabled = enabled
    }

    public static func sanitizeShortcutName(_ name: String, fallback: String = "") -> String {
        var sanitized = name.components(separatedBy: .controlCharacters).joined()
        sanitized = sanitized.replacingOccurrences(of: "\n", with: "")
        sanitized = sanitized.replacingOccurrences(of: "\r", with: "")
        sanitized = sanitized.replacingOccurrences(of: "/", with: "")
        sanitized = sanitized.replacingOccurrences(of: ":", with: "")
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.count > 100 {
            sanitized = String(sanitized.prefix(100)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return sanitized.isEmpty ? fallback : sanitized
    }

    public var turnOffDataShortcutName: String {
        let raw = UserDefaults.standard.turnOffDataShortcutName
        return Self.sanitizeShortcutName(raw, fallback: AppConstants.Shortcuts.defaultTurnOffDataShortcutName)
    }

    public var turnOnDataShortcutName: String {
        let raw = UserDefaults.standard.turnOnDataShortcutName
        return Self.sanitizeShortcutName(raw, fallback: AppConstants.Shortcuts.defaultTurnOnDataShortcutName)
    }

    public func setTurnOffDataShortcutName(_ name: String) {
        let sanitized = Self.sanitizeShortcutName(name, fallback: AppConstants.Shortcuts.defaultTurnOffDataShortcutName)
        UserDefaults.standard.turnOffDataShortcutName = sanitized
    }

    public func setTurnOnDataShortcutName(_ name: String) {
        let sanitized = Self.sanitizeShortcutName(name, fallback: AppConstants.Shortcuts.defaultTurnOnDataShortcutName)
        UserDefaults.standard.turnOnDataShortcutName = sanitized
    }

    public func shortcutURL(for name: String, fallback: String) -> URL {
        let sanitized = Self.sanitizeShortcutName(name, fallback: fallback)
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: sanitized)]
        return components.url ?? URL(string: "shortcuts://run-shortcut?name=\(fallback)")!
    }

    @MainActor
    private static func isAppForeground() -> Bool {
        UIApplication.shared.applicationState == .active &&
        UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
    }

    @MainActor
    private static func openShortcut(_ url: URL) async -> Bool {
        guard isAppForeground() else { return false }
        let accepted = await UIApplication.shared.open(url)
        debugLog("[CellularRefreshManager] Shortcut launch accepted: \(accepted); waiting for its completion callback.")
        return accepted
    }

    private var shortcutSettings: CellularRefreshCoordinator.Settings {
        .init(offName: turnOffDataShortcutName, onName: turnOnDataShortcutName,
              callbackScheme: Self.callbackScheme,
              offDelay: turnOffDataBaseDelayOverride ?? AppConstants.Shortcuts.defaultTurnOffDataBaseDelay,
              onDelay: turnOnDataBaseDelayOverride ?? AppConstants.Shortcuts.defaultTurnOnDataBaseDelay)
    }

    private static var callbackScheme: String {
        // Read the physical host's plist, bypassing LiveContainer's active-bundle hooks.
        var hostURL = Bundle.main.bundleURL
        while hostURL.pathExtension != "app" && hostURL.path != "/" {
            hostURL.deleteLastPathComponent()
        }
        let plist = NSDictionary(contentsOf: hostURL.appendingPathComponent("Info.plist"))
        let types = plist?["CFBundleURLTypes"] as? [[String: Any]] ?? []
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        if let primary = schemes.first, primary != "sidestore" { return primary }
        return schemes.first(where: { $0.hasPrefix("sidestore-") }) ?? "sidestore"
    }

    public var turnOffDataBaseDelayOverride: TimeInterval? {
        guard let value = UserDefaults.standard.object(forKey: "turnOffDataBaseDelayOverride") as? Double else {
            return nil
        }
        return max(0, value)
    }

    public var turnOnDataBaseDelayOverride: TimeInterval? {
        guard let value = UserDefaults.standard.object(forKey: "turnOnDataBaseDelayOverride") as? Double else {
            return nil
        }
        return max(0, value)
    }

    public func setTurnOffDataBaseDelayOverride(_ delay: TimeInterval?) {
        if let delay = delay {
            UserDefaults.standard.set(max(0, delay), forKey: "turnOffDataBaseDelayOverride")
        } else {
            UserDefaults.standard.removeObject(forKey: "turnOffDataBaseDelayOverride")
        }
    }

    public func setTurnOnDataBaseDelayOverride(_ delay: TimeInterval?) {
        if let delay = delay {
            UserDefaults.standard.set(max(0, delay), forKey: "turnOnDataBaseDelayOverride")
        } else {
            UserDefaults.standard.removeObject(forKey: "turnOnDataBaseDelayOverride")
        }
    }

    public func resetToDefaults() {
        setTurnOffDataShortcutName(AppConstants.Shortcuts.defaultTurnOffDataShortcutName)
        setTurnOnDataShortcutName(AppConstants.Shortcuts.defaultTurnOnDataShortcutName)
        setTurnOffDataBaseDelayOverride(nil)
        setTurnOnDataBaseDelayOverride(nil)
    }

    // zh-patch: Each pipeline owns its cellular cleanup, including failure and cancellation.
    public func withRestorationScope<Value>(_ operation: () async throws -> Value) async throws -> Value {
        try await coordinator.withRestorationScope(operation)
    }

    @discardableResult
    public func turnOffDataIfNeeded(addOnDelay: TimeInterval = 0) async throws -> Bool {
        try await coordinator.turnOffDataIfNeeded(addOnDelay: addOnDelay)
    }

    @discardableResult
    public func turnOnDataIfNeeded(addOnDelay: TimeInterval = 0) async throws -> Bool {
        try await coordinator.turnOnDataIfNeeded(addOnDelay: addOnDelay)
    }

    public func checkBackgroundRefreshAllowed() async throws {
        guard isSupported, isEnabled else { return }
        if await CellularPathProbe.isAvailable(.wifi) == true { return }
        guard let cellularAvailable = await CellularPathProbe.isAvailable(.cellular) else {
            throw CellularRefreshError.networkUnknown
        }
        if cellularAvailable { throw CellularRefreshError.foregroundRequired }
    }

    public func restoreBeforeSuspending() async -> Bool {
        do {
            try await turnOnDataIfNeeded()
            guard UserDefaults.standard.string(forKey: Self.pendingRestoreKey) == nil else {
                throw CellularRefreshError.recoveryRequired
            }
            return true
        } catch {
            await showRecoveryError(error)
            return false
        }
    }

    fileprivate func handleCallback(_ url: URL) -> Bool {
        coordinator.handleCallback(url)
    }

    public func retryPendingData() {
        recoverPendingData(allowRetry: true)
    }

    fileprivate func recoverPendingData(allowRetry: Bool = false) {
        Task {
            do { try await coordinator.recoverPendingData(allowRetry: allowRetry) }
            catch {
                debugLog("[CellularRefreshManager] Pending recovery requires attention: \(error.localizedDescription)")
                await showRecoveryError(error)
            }
        }
    }

    @MainActor
    private func showRecoveryError(_ error: Error) {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) else { return }
        ToastView(text: NSLocalizedString("Cellular Data Needs Attention", comment: ""),
                  detailText: error.localizedDescription).show(in: window)
    }
}

// Called by both SideStore and the actual LiveContainer host, without starting a refresh.
@objc(SSCellularRefreshBridge)
final class SSCellularRefreshBridge: NSObject {
    @objc(handleCallback:)
    static func handleCallback(_ url: URL) -> Bool {
        CellularRefreshManager.shared.handleCallback(url)
    }

    @objc static func recoverPendingData() {
        CellularRefreshManager.shared.recoverPendingData()
    }
}

private final class CellularPathProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let monitor: NWPathMonitor
    private var continuation: CheckedContinuation<Bool?, Never>?

    private init(_ type: NWInterface.InterfaceType, continuation: CheckedContinuation<Bool?, Never>) {
        monitor = NWPathMonitor(requiredInterfaceType: type)
        self.continuation = continuation
    }

    static func isAvailable(_ type: NWInterface.InterfaceType) async -> Bool? {
        await withCheckedContinuation { continuation in
            let probe = CellularPathProbe(type, continuation: continuation)
            probe.monitor.pathUpdateHandler = { path in probe.finish(path.status == .satisfied) }
            probe.monitor.start(queue: DispatchQueue.global(qos: .utility))
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                probe.finish(nil)
            }
        }
    }

    private func finish(_ available: Bool?) {
        let completion = lock.withLock {
            let result = continuation
            continuation = nil
            return result
        }
        guard let completion else { return }
        monitor.cancel()
        monitor.pathUpdateHandler = nil
        completion.resume(returning: available)
    }
}
