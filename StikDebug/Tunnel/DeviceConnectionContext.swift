//
//  DeviceConnectionContext.swift
//  StikDebug
//
//  Created by Stephen.
//

import Foundation

enum DeviceConnectionContext {
    static let defaultTargetIPAddress = "10.7.0.1"

    static var targetIPAddress: String {
        let stored = UserDefaults.standard
            .string(forKey: UserDefaults.Keys.targetDeviceIP)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored, !stored.isEmpty else {
            return defaultTargetIPAddress
        }
        return stored
    }

    static var candidateIPs: [String] {
        let current = targetIPAddress
        var list = [current]
        let defaults = ["10.7.0.1", "10.7.0.2", "127.0.0.1"]
        for ip in defaults where !list.contains(ip) {
            list.append(ip)
        }
        return list
    }

    static func recordWorkingIP(_ ip: String) {
        let clean = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        UserDefaults.standard.set(clean, forKey: UserDefaults.Keys.targetDeviceIP)
    }
}
