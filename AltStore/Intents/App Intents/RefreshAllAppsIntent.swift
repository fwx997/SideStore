//
//  RefreshAllAppsIntent.swift
//  AltStore
//
//  Created by Riley Testut on 8/18/23.
//  Copyright © 2023 Riley Testut. All rights reserved.
//

import AppIntents

// Shouldn't conform types we don't own to protocols we don't own, so make custom
// NSError subclass that conforms to CustomLocalizedStringResourceConvertible instead.
//
// Would prefer to just conform ALTLocalizedError to CustomLocalizedStringResourceConvertible,
// but that can't be done without raising minimum version for ALTLocalizedError to iOS 16 :/
@available(iOS 16, tvOS 16, *)
class IntentError: NSError, CustomLocalizedStringResourceConvertible, @unchecked Sendable
{
    var localizedStringResource: LocalizedStringResource {
        return "\(self.localizedDescription)"
    }
    
    init(_ error: some Error)
    {
        let serializedError = (error as NSError).sanitizedForSerialization()
        super.init(domain: serializedError.domain, code: serializedError.code, userInfo: serializedError.userInfo)
    }
    
    required init?(coder: NSCoder)
    {
        super.init(coder: coder)
    }
}

@available(iOS 17.0, tvOS 17.0, *)
struct InstallIPAIntent: AppIntent, ProgressReportingIntent
{
    static var title: LocalizedStringResource = "Install IPA"
    static var description = IntentDescription("Installs an IPA file with SideStore.")
    static var openAppWhenRun = false

    @Parameter(title: "IPA File")
    var ipaFile: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Install \(\.$ipaFile)")
    }

    init()
    {
        self.progress.completedUnitCount = 0
        self.progress.totalUnitCount = 1
    }

    func perform() async throws -> some IntentResult
    {
        do
        {
            try await DatabaseManager.shared.start()

            let temporaryDirectory = FileManager.default.uniqueTemporaryURL()
            defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

            let ipaURL = temporaryDirectory.appendingPathComponent("App.ipa")
            try self.ipaFile.data.write(to: ipaURL)

            let intentProgress = self.progress
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<InstalledApp, Error>) in
                let group = AppManager.shared.install(.url(ipaURL)) { result in
                    continuation.resume(with: result)
                }
                intentProgress.addChild(group.progress, withPendingUnitCount: 1)
            }

            return .result()
        }
        catch
        {
            let intentError = IntentError(error)
            throw intentError
        }
    }
}


@available(iOS 17.0, tvOS 17.0, *)
struct RefreshAllAppsIntent: AppIntent, CustomIntentMigratedAppIntent, PredictableIntent, ProgressReportingIntent, ForegroundContinuableIntent
{
    static let intentClassName = "RefreshAllIntent"
    static var openAppWhenRun = false
    
    static var title: LocalizedStringResource = "Refresh All Apps"
    static var description = IntentDescription("Refreshes your sideloaded apps to prevent them from expiring.")
    
    static var parameterSummary: some ParameterSummary {
        Summary("Refresh All Apps")
    }
    
    static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction {
            DisplayRepresentation(
                title: "Refresh All Apps",
                subtitle: ""
            )
        }
    }
    
    let presentsNotifications: Bool
    
    init(presentsNotifications: Bool)
    {
        self.presentsNotifications = presentsNotifications
        
        self.progress.completedUnitCount = 0
        self.progress.totalUnitCount = 1
    }
    
    init()
    {
        self.init(presentsNotifications: false)
    }
    
    func perform() async throws -> some IntentResult & ProvidesDialog
    {
        let session = BackgroundRefreshSession(deadline: .now + .seconds(27))
        // Do not await this worker on exit: shared database initialization may outlive
        // cancellation. Session checks prevent that late initialization from starting work.
        let preparation = Task {
            do { try await self.refreshAllApps(session: session) }
            catch { session.finish(.failure(error)) }
        }
        defer { preparation.cancel() }
        do
        {
            try await session.wait()
            
            return .result(dialog: "All apps have been refreshed.")
        }
        catch
        {
            let intentError = IntentError(error)
            throw intentError
        }
    }
}

@available(iOS 17.0, tvOS 17.0, *)
private extension RefreshAllAppsIntent
{
    func refreshAllApps(session: BackgroundRefreshSession) async throws
    {
        try session.checkCanContinue()
        try await CellularRefreshManager.shared.checkBackgroundRefreshAllowed()
        try session.checkCanContinue()
        try await DatabaseManager.shared.start()
        try session.checkCanContinue()
        
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        let installedApps = await context.perform { InstalledApp.fetchAppsForRefreshingAll(in: context) }
        try session.checkCanContinue()
        guard !installedApps.isEmpty else {
            session.finish(.success(()))
            return
        }

        try session.dispatch {
            let operation = try AppManager.shared.backgroundRefresh(
                installedApps, presentsNotifications: self.presentsNotifications,
                ignoresServerNotFoundError: false
            ) { result in
                session.finish(Self.refreshResult(result))
            }
            self.progress.addChild(operation.progress, withPendingUnitCount: 1)
        }
    }

    static func refreshResult(_ result: Result<[String: Result<InstalledApp, Error>], Error>) -> Result<Void, Error> {
        do {
            let results = try result.get()
            for result in results.values {
                if case .failure(let error) = result { throw error }
            }
            return .success(())
        } catch OperationError.noInstalledApps {
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}
