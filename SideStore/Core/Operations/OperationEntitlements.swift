//
//  OperationEntitlements.swift
//  SideStore
//
//  Created by Magesh K on 30/07/26.
//  Copyright © 2026 AltStore. All rights reserved.
//

import Foundation
import SideSign

struct OperationEntitlements {
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
}
