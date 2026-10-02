//
//  BackgroundTaskManager.swift
//  AltStore
//
//  Created by Riley Testut on 6/19/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import Foundation

@MainActor
final class BackgroundTaskManager
{
    static let shared = BackgroundTaskManager()

    private init() {}
}

extension BackgroundTaskManager
{
    func performExtendedBackgroundTask(taskHandler: @escaping ((Result<Void, Error>, @escaping () -> Void) -> Void))
    {
        // Share the lifetime of foreground pipelines instead of running a second audio engine.
        let identifier = BackgroundServiceManager.beginTask()
        taskHandler(.success(())) {
            Task { @MainActor in
                BackgroundServiceManager.endTask(identifier)
            }
        }
    }
}
