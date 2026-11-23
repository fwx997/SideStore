//
//  RefreshAppOperation.swift
//  AltStore
//
//  Created by Riley Testut on 2/27/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

import Foundation
import CoreData
import SideSign

final class RefreshAppOperation: BasePipelineOperation<InstallAppOperationContext, InstalledApp>, @unchecked Sendable {
    
    override func execute(parentProgress: Progress?) async throws -> InstalledApp {
        let startTime = CFAbsoluteTimeGetCurrent()
        debugLog("[RefreshAppOperation] execute() started")
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            debugLog("[RefreshAppOperation] execute() took: \(String(format: "%.3fs", elapsed))")
        }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        
        guard let profiles = self.context.provisioningProfiles else {
            throw OperationError.invalidParameters("RefreshAppOperation.execute: self.context.provisioningProfiles is nil")
        }
        
        guard let appBundle = self.context.targetAppBundle else {
            throw OperationError.invalidParameters("RefreshAppOperation: context.targetAppBundle is nil")
        }
        try await context.dbBackgroundContext.perform {
            try self.validateMemoryGrants(profiles: profiles, appBundle: appBundle)
        }
        self.setProgress(10)
        
        if self.context.isCellularRefreshGroup {
            guard let app = self.context.installedApp else {
                throw OperationError.invalidParameters("RefreshAppOperation: context.installedApp is nil")
            }
            debugLog("[RefreshAppOperation] Queueing \(self.context.bundleIdentifier) into batch profile injection (isCellularRefreshGroup = true)")
            self.context.sharedContext.addPendingProfileBatch(PendingProfileBatch(
                bundleID: self.context.bundleIdentifier,
                profiles: profiles,
                app: app,
                certStatus: self.context.targetCertStatus
            ))
            self.setProgress(85)
            return app
        }
        
        do {
            try await CellularRefreshManager.shared.turnOffDataIfNeeded()
            for p in profiles {
                try await installProvisioningProfiles(p.value.data)
            }
            try await CellularRefreshManager.shared.turnOnDataIfNeeded()
        } catch {
            try? await CellularRefreshManager.shared.turnOnDataIfNeeded()
            throw error
        }
        
        self.setProgress(80)
        let dbContext = self.context.dbBackgroundContext
        
        let installedApp = try await dbContext.perform {
            try self.updateInstalledApp(for: appBundle, profiles: profiles, in: dbContext)
        }
        
        self.setProgress(100)
        return installedApp
    }

    private func validateMemoryGrants(profiles: [String: ALTProvisioningProfile], appBundle: ALTApplication) throws {
        guard let installedApp = context.installedApp else {
            throw OperationError.invalidParameters("RefreshAppOperation: context.installedApp is nil")
        }
        let mainProfile = profiles.values.first { $0.bundleIdentifier == installedApp.resignedBundleIdentifier }
            ?? profiles[context.targetBundleIdentifier]
        try OperationEntitlements.validateRefreshMemoryGrant(
            claimed: installedApp.customEntitlements ?? appBundle.entitlements,
            profile: mainProfile?.entitlements ?? [:],
            bundleIdentifier: installedApp.resignedBundleIdentifier
        )
        for appExtension in installedApp.appExtensions {
            let bundle = appBundle.appExtensions.first {
                $0.bundleIdentifier == appExtension.bundleIdentifier || $0.bundleIdentifier == appExtension.resignedBundleIdentifier
            }
            let profile = context.useMainProfile ? mainProfile : profiles.values.first {
                $0.bundleIdentifier == appExtension.resignedBundleIdentifier
            }
            try OperationEntitlements.validateRefreshMemoryGrant(
                claimed: appExtension.customEntitlements ?? bundle?.entitlements ?? [:],
                profile: profile?.entitlements ?? [:],
                bundleIdentifier: appExtension.resignedBundleIdentifier
            )
        }
    }
    
    private func updateInstalledApp(for appBundle: ALTApplication, profiles: [String: ALTProvisioningProfile], in dbContext: NSManagedObjectContext) throws -> InstalledApp {
        self.setProgress(self.progress.completedUnitCount + 1)
        
        guard let mainApp = self.context.installedApp,
              let installedApp = dbContext.object(with: mainApp.objectID) as? InstalledApp else {
            throw OperationError.invalidParameters("Could not find installed database record for '\(appBundle.name)'")
        }
        try installedApp.update(provisioningProfiles: profiles)
        
        if let certStatus = self.context.targetCertStatus {
            installedApp.certificateStatus = certStatus
        }

        return installedApp
    }
}
