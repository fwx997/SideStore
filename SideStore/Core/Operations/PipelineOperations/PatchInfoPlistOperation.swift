//
//  PatchInfoPlistOperation.swift
//  SideStore
//
//  Created by Magesh K on 13/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation

final class PatchInfoPlistOperation: BasePipelineOperation<InstallAppOperationContext, Void>, @unchecked Sendable {
    override func execute(parentProgress: Progress?) async throws {
        let startTime = CFAbsoluteTimeGetCurrent()
        debugLog("[PatchInfoPlistOperation] execute() started")
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            debugLog("[PatchInfoPlistOperation] execute() took: \(String(format: "%.3fs", elapsed))")
        }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        
        let bundleID = self.context.targetBundleIdentifier
        let customPlistURL = InstalledApp.appsDirectoryURL.appendingPathComponent(bundleID).appendingPathComponent("custom_info.plist")
        
        guard FileManager.default.fileExists(atPath: customPlistURL.path) else {
            debugLog("[PatchInfoPlistOperation] No custom_info.plist found for \(bundleID). Skipping.")
            return
        }
        
        do {
            let customParser = try InfoPlistParser(plistURL: customPlistURL)
            self.context.customInfoPlist = customParser.rawDictionary
            
            if let customID = customParser.bundleIdentifier,
               !customID.isEmpty,
               customID != self.context.bundleIdentifier {
                self.context.customBundleIdentifier = customID
            }
            
            if let targetAppBundle = self.context.targetAppBundle {
                var targetParser = try InfoPlistParser(plistURL: targetAppBundle.bundle.infoPlistURL)
                targetParser.merge(customParser.rawDictionary)
                try targetParser.write(to: targetAppBundle.bundle.infoPlistURL)
                debugLog("[PatchInfoPlistOperation] Successfully patched staged app Info.plist for \(bundleID)")
            }
        } catch {
            debugLog("[PatchInfoPlistOperation] Error applying custom Info.plist: \(error)")
            throw error
        }
    }
}
