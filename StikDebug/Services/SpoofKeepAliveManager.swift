//
//  SpoofKeepAliveManager.swift
//  StikDebug
//

import Foundation
import UIKit

final class SpoofKeepAliveManager: ObservableObject {
    static let shared = SpoofKeepAliveManager()

    @Published private(set) var isActive: Bool = false

    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    private init() {}

    func activate() {
        if Thread.isMainThread {
            performActivate()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.performActivate()
            }
        }
    }

    func deactivate() {
        if Thread.isMainThread {
            performDeactivate()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.performDeactivate()
            }
        }
    }

    private func performActivate() {
        guard !isActive else { return }
        isActive = true
        BackgroundAudioManager.shared.start()
        BackgroundLocationManager.shared.start()

        if backgroundTaskID == .invalid {
            backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "SpoofKeepAlive") { [weak self] in
                guard let self else { return }
                LogManager.shared.addInfoLog("SpoofKeepAlive background task expired")
                self.endBackgroundTask()
                if self.isActive {
                    self.backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "SpoofKeepAliveRenewal") { [weak self] in
                        self?.endBackgroundTask()
                    }
                }
            }
        }
    }

    private func performDeactivate() {
        guard isActive || backgroundTaskID != .invalid else {
            isActive = false
            return
        }
        isActive = false
        BackgroundAudioManager.shared.stop()
        BackgroundLocationManager.shared.stop()
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }
}
