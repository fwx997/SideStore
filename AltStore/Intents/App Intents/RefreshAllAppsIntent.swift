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

    @Parameter(title: "Return Errors as Result", default: false)
    var returnErrorsAsResult: Bool
    
    static var parameterSummary: some ParameterSummary {
        Summary("Refresh All Apps") {
            \.$returnErrorsAsResult
        }
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
    
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String>
    {
        let requestID = UUID().uuidString
        do
        {
            let execution = try ShortcutRefreshExecution(requestID: requestID, progress: progress,
                                                         presentsNotifications: presentsNotifications)
            execution.start()
            try await execution.wait()
            let result = ShortcutRefreshResult.success(requestID: requestID, message: NSLocalizedString("All apps have been refreshed.", comment: ""))
            return .result(value: result.json, dialog: "\(result.message)")
        }
        catch
        {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            let intentError = IntentError(error)
            guard returnErrorsAsResult else { throw intentError }
            let result = ShortcutRefreshResult.failure(intentError, requestID: requestID)
            return .result(value: result.json, dialog: "\(result.message)")
        }
    }
}

@available(iOS 17.0, tvOS 17.0, *)
struct GetRefreshResultIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Refresh Result"
    static var description = IntentDescription("Checks one refresh request without starting another refresh.")
    static var openAppWhenRun = false

    @Parameter(title: "Request ID")
    var requestID: String

    static var parameterSummary: some ParameterSummary { Summary("Get refresh result for \(\.$requestID)") }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let result: ShortcutRefreshResult
        do { result = try ShortcutRefreshEnvironment.store().query(requestID: requestID) }
        catch { result = .unknown(requestID: requestID, message: error.localizedDescription) }
        return .result(value: result.json, dialog: "\(result.message)")
    }
}
