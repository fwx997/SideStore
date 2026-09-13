//
//  CacheInfoPlistOperation.swift
//  SideStore
//
//  Created by Magesh K on 13/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation

final class CacheInfoPlistOperation: BasePipelineOperation<InstallAppOperationContext, Void>, @unchecked Sendable {
    override func execute(parentProgress: Progress?) async throws {
        let startTime = CFAbsoluteTimeGetCurrent()
        debugLog("[CacheInfoPlistOperation] execute() started")
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            debugLog("[CacheInfoPlistOperation] execute() took: \(String(format: "%.3fs", elapsed))")
        }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        
        let bundleID = self.context.targetBundleIdentifier
        if bundleID.isAltStoreAppID {
            debugLog("[CacheInfoPlistOperation] Skipping caching of custom Info.plist for self (\(bundleID)).")
            return
        }
        
        guard let customPlist = self.context.customInfoPlist else {
            debugLog("[CacheInfoPlistOperation] No custom Info.plist found in context to cache for \(bundleID).")
            return
        }
        
        let appsDirectory = InstalledApp.appsDirectoryURL
        let appDirectory = appsDirectory.appendingPathComponent(bundleID)
        
        do {
            try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true, attributes: nil)
            let plistURL = appDirectory.appendingPathComponent("custom_info.plist")
            let plistData = try PropertyListSerialization.data(fromPropertyList: customPlist, format: .xml, options: 0)
            try plistData.write(to: plistURL, options: .atomic)
            debugLog("[CacheInfoPlistOperation] Successfully cached custom Info.plist to \(plistURL.path)")
        } catch {
            debugLog("[CacheInfoPlistOperation] ERROR: Failed to write custom Info.plist to disk: \(error)")
            throw error
        }
    }
}
