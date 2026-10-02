//
//  BackgroundService.swift
//  SideStore
//
//  Created by Magesh K on 15/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation

public protocol BackgroundService: Sendable {
    var isRunning: Bool { get }
    @discardableResult
    func start() -> Bool
    func stop()
    func prepare() async -> Bool
}

public extension BackgroundService {
    func prepare() async -> Bool { true }
}

public enum BackgroundServiceMode: String, CaseIterable, Sendable {
    case audio
    case location

    public var displayName: String {
        switch self {
        case .audio:
            return NSLocalizedString("Audio", comment: "Background keepalive mode")
        case .location:
            return NSLocalizedString("Location", comment: "Background keepalive mode")
        }
    }

    public var subtitle: String {
        switch self {
        case .audio:
            return NSLocalizedString("Silent audio while tasks are running", comment: "Background keepalive mode description")
        case .location:
            return NSLocalizedString("Location updates while tasks are running", comment: "Background keepalive mode description")
        }
    }
}

@MainActor
public final class BackgroundServiceManager {
    private static var activeTasks: Set<UUID> = []
    private static var isSuspended = false

    public static var shared: any BackgroundService {
        service(for: UserDefaults.standard.backgroundServiceMode)
    }

    public static func service(for mode: BackgroundServiceMode) -> any BackgroundService {
        switch mode {
        case .audio:
            return BackgroundAudioService.shared
        case .location:
            return BackgroundLocationService.shared
        }
    }

    public static func stop() {
        // Self-reinstallation must stay suspended until the current tasks finish.
        isSuspended = true
        shared.stop()
    }

    public static func beginTask() -> UUID {
        if activeTasks.isEmpty {
            isSuspended = false
        }
        let identifier = UUID()
        activeTasks.insert(identifier)
        ensureBackgroundServicesStarted()
        return identifier
    }

    public static func endTask(_ identifier: UUID) {
        guard activeTasks.remove(identifier) != nil else { return }
        guard activeTasks.isEmpty else { return }
        shared.stop()
        isSuspended = false
    }

    public static func switchTo(mode: BackgroundServiceMode) {
        shared.stop()
        UserDefaults.standard.backgroundServiceMode = mode
        ensureBackgroundServicesStarted()
    }

    public static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.isBackgroundServiceEnabled = enabled
        ensureBackgroundServicesStarted()
    }

    @discardableResult
    public static func ensureBackgroundServicesStarted() -> Bool {
        guard !activeTasks.isEmpty, !isSuspended,
              UserDefaults.standard.isBackgroundServiceEnabled else {
            shared.stop()
            return false
        }
        if !shared.isRunning {
            return shared.start()
        }
        return true
    }

    private init() {}
}
