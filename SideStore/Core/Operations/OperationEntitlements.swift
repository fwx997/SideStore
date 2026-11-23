//
//  OperationEntitlements.swift
//  SideStore
//
//  Created by Magesh K on 30/07/26.
//  Copyright © 2026 AltStore. All rights reserved.
//

import Foundation
import CoreFoundation
import SideSign

struct OperationEntitlements {
    struct Selection {
        let values: [String: any Sendable]?
        let pendingMemoryRequest: MemoryCapabilityRequestStore.Request?
    }

    static func recordEnabledCapabilityRequests(for resignedBundleIdentifier: String, capabilities: [String]) {
        MemoryCapabilityRequestStore.shared.recordEnabledCapabilityRequests(
            for: resignedBundleIdentifier, capabilities: capabilities
        )
    }

    static let defaultAdditionalEntitlements: [ALTEntitlement: any Sendable] = [
        .increasedDebuggingMemoryLimit  : true,
        .increasedMemoryLimit           : true,
        .extendedVirtualAddressing      : true
    ]

    static func merging(
        _ entitlements: [String: any Sendable],
        additional: [ALTEntitlement: any Sendable],
        preservingMemorySelection: Bool
    ) -> [String: any Sendable] {
        var result = entitlements
        for (key, value) in additional {
            // Memory defaults are fallbacks; an explicit/cached selection also
            // wins when the user removed the key from that selection.
            if defaultAdditionalEntitlements[key] != nil,
               preservingMemorySelection || entitlements[key.rawValue] != nil {
                continue
            }
            result[key.rawValue] = value
        }
        return result
    }

    static func requested(
        for appBundle: ALTApplication,
        identifiers: [String],
        resignedBundleIdentifier: String,
        custom: [String: [String: any Sendable]],
        explicitMemorySelections: Set<String>? = nil,
        installedApp: InstalledApp?,
        additional: [ALTEntitlement: any Sendable],
        requestStore: MemoryCapabilityRequestStore = .shared
    ) -> Selection {
        let explicit = identifiers.compactMap { custom[$0] }.first
        let memoryIsExplicit = explicitMemorySelections.map { !$0.isDisjoint(with: identifiers) } ?? (explicit != nil)
        let cached = cached(for: appBundle, identifiers: identifiers, installedApp: installedApp)
        var pending = requestStore.request(for: resignedBundleIdentifier)
        var selection = explicit ?? cached
        if let request = pending, memoryIsExplicit, let explicit, disablesMemory(explicit) {
            requestStore.consume(request)
            pending = nil
        }
        if pending != nil, !memoryIsExplicit {
            selection = selection ?? appBundle.entitlements
            selection?[ALTEntitlement.increasedMemoryLimit.rawValue] = true
        }
        guard !appBundle.isExtension, !additional.isEmpty else {
            return Selection(values: selection, pendingMemoryRequest: pending)
        }
        return Selection(
            values: merging(selection ?? appBundle.entitlements, additional: additional, preservingMemorySelection: selection != nil),
            pendingMemoryRequest: pending
        )
    }

    static func preparingCustomization(
        _ entitlements: [String: any Sendable],
        resignedBundleIdentifier: String,
        requestStore: MemoryCapabilityRequestStore = .shared
    ) -> [String: any Sendable] {
        guard requestStore.request(for: resignedBundleIdentifier) != nil else { return entitlements }
        var selected = entitlements
        selected[ALTEntitlement.increasedMemoryLimit.rawValue] = true
        return selected
    }

    static func isMemoryEnabled(_ entitlements: [String: any Sendable]) -> Bool {
        guard let value = entitlements[ALTEntitlement.increasedMemoryLimit.rawValue] as? NSNumber else { return false }
        return CFGetTypeID(value) == CFBooleanGetTypeID() && value.boolValue
    }

    private static func disablesMemory(_ entitlements: [String: any Sendable]) -> Bool {
        guard let raw = entitlements[ALTEntitlement.increasedMemoryLimit.rawValue] else { return true }
        guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return !value.boolValue
    }

    static func validateSigningMemoryGrant(
        requested: [String: any Sendable],
        cached: [String: any Sendable]?,
        pendingRequest: MemoryCapabilityRequestStore.Request?,
        profile: [String: any Sendable],
        bundleIdentifier: String
    ) throws {
        let preservingGrant = cached.map(isMemoryEnabled) ?? false
        guard isMemoryEnabled(requested), pendingRequest != nil || preservingGrant else { return }
        guard isMemoryEnabled(profile) else {
            let format = NSLocalizedString(
                "Apple did not grant Increased Memory Limit for %@. Reinstall stopped before changing the app's signature.",
                comment: "A tool request or an existing memory grant must be preserved during reinstall"
            )
            throw OperationError.invalidApp(reason: String(format: format, bundleIdentifier))
        }
    }

    static func cached(
        for appBundle: ALTApplication,
        identifiers: [String],
        installedApp: InstalledApp?
    ) -> [String: any Sendable]? {
        guard let installedApp else { return nil }
        if !appBundle.isExtension { return installedApp.customEntitlements }
        return installedApp.appExtensions.first {
            identifiers.contains($0.bundleIdentifier) || identifiers.contains($0.resignedBundleIdentifier)
        }?.customEntitlements
    }

    /// Refresh replaces profiles without signing the installed executable again.
    /// Reject a lost grant before either direct or batched profile injection.
    static func validateRefreshMemoryGrant(
        claimed: [String: any Sendable],
        profile: [String: any Sendable],
        bundleIdentifier: String
    ) throws {
        let key = ALTEntitlement.increasedMemoryLimit.rawValue
        guard let value = claimed[key] else { return }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw OperationError.invalidApp(reason: NSLocalizedString(
                "The installed memory entitlement must be a Boolean.", comment: "Malformed cached memory entitlement"
            ))
        }
        guard number.boolValue else { return }
        guard let granted = profile[key] as? NSNumber,
              CFGetTypeID(granted) == CFBooleanGetTypeID(), granted.boolValue else {
            let format = NSLocalizedString(
                "Apple did not grant Increased Memory Limit for %@. Refresh stopped before replacing its provisioning profile.",
                comment: "Refreshing an app that already claims the increased memory entitlement"
            )
            throw OperationError.invalidApp(reason: String(format: format, bundleIdentifier))
        }
    }
}
