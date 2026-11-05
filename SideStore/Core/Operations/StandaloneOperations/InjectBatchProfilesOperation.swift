//
//  InjectBatchProfilesOperation.swift
//  SideStore
//
//  Created by Magesh K on 14/09/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import CoreData
import SideSign

final class InjectBatchProfilesOperation: BaseStandaloneOperation<StandaloneOperationContext, Void>, @unchecked Sendable {
    let batches: [PendingProfileBatch]
    var onAppCompleted: (@Sendable (String, InstalledApp) async throws -> Void)?

    init(
        batches: [PendingProfileBatch],
        context: StandaloneOperationContext,
        onAppCompleted: (@Sendable (String, InstalledApp) async throws -> Void)? = nil
    ) throws {
        self.batches = batches
        self.onAppCompleted = onAppCompleted
        try super.init(context: context)
    }

    override func execute(parentProgress: Progress?) async throws {
        let startTime = CFAbsoluteTimeGetCurrent()
        debugLog("[InjectBatchProfilesOperation] execute() started")
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            debugLog("[InjectBatchProfilesOperation] execute() took: \(String(format: "%.3fs", elapsed))")
        }
        try await super.executePreconditionCheck(parentProgress: parentProgress)

        guard !self.batches.isEmpty else {
            debugLog("[InjectBatchProfilesOperation] No pending profiles collected across batch, skipping")
            return
        }

        debugLog("[InjectBatchProfilesOperation] Running batch injection for \(self.batches.count) app(s)")

        // zh-patch: Batch failures/cancellation must restore data just like single-app refresh.
        try await CellularRefreshManager.shared.withRestorationScope {
            try await self.injectBatches()
        }
        debugLog("[InjectBatchProfilesOperation] Batch profile injection completed for all \(self.batches.count) app(s)")
        self.setProgress(100)
    }

    private func injectBatches() async throws {
        try await CellularRefreshManager.shared.turnOffDataIfNeeded()
        for batch in self.batches {
            try Task.checkCancellation()
            debugLog("[InjectBatchProfilesOperation] Installing \(batch.profiles.count) profile(s) for \(batch.bundleID)...")
            for profile in batch.profiles.values {
                try Task.checkCancellation()
                try await installProvisioningProfiles(profile.data)
            }

            let installedApp = try await self.updateInstalledApp(for: batch)
            try await self.onAppCompleted?(batch.bundleID, installedApp)
            debugLog("[InjectBatchProfilesOperation] Successfully processed \(batch.bundleID)")
        }
        try await CellularRefreshManager.shared.turnOnDataIfNeeded()
    }

    private func updateInstalledApp(for batch: PendingProfileBatch) async throws -> InstalledApp {
        let dbContext = self.context.dbBackgroundContext
        let objectID = batch.app.objectID
        return try await dbContext.perform {
            guard let installedApp = try dbContext.existingObject(with: objectID) as? InstalledApp else {
                throw OperationError.invalidParameters("Could not find installed database record for '\(batch.bundleID)'")
            }
            // Only persist new dates after every profile for this app was installed.
            // The cellular device path still needs proper testing on a real phone.
            try installedApp.update(provisioningProfiles: batch.profiles)
            if let certStatus = batch.certStatus {
                installedApp.certificateStatus = certStatus
            }
            try dbContext.save()
            return installedApp
        }
    }
}
