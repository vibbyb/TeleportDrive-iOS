//
//  PairingFileStore.swift
//  StikDebug
//

import Foundation
import UniformTypeIdentifiers

enum PairingFileStore {
    static let fileName = "rp_pairing_file.plist"
    static let supportedContentTypes: [UTType] = [
        UTType(filenameExtension: "mobiledevicepairing", conformingTo: .data)!,
        UTType(filenameExtension: "mobiledevicepair", conformingTo: .data)!,
        .propertyList
    ]

    private static let legacyFileName = "pairingFile.plist"
    private static let userCustomImportKey = "hasUserImportedCustomPairing"

    static var hasUserImportedCustomPairing: Bool {
        get { UserDefaults.standard.bool(forKey: userCustomImportKey) }
        set { UserDefaults.standard.set(newValue, forKey: userCustomImportKey) }
    }

    static var hasPairingFile: Bool {
        FileManager.default.fileExists(atPath: prepareURL().path)
    }

    static var url: URL {
        directoryURL.appendingPathComponent(fileName)
    }

    static func isValidIdevicePairing(at url: URL, fileManager: FileManager = .default) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any] else {
            return false
        }

        guard let pubKey = dict["public_key"] as? Data, pubKey.count == 32,
              let privKey = dict["private_key"] as? Data, privKey.count == 32,
              let identifier = dict["identifier"] as? String,
              !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        return true
    }

    static func normalizePairingData(_ data: Data) -> Data? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: .mutableContainersAndLeaves, format: nil),
              var dict = plist as? [String: Any] else {
            return nil
        }

        guard let pubKey = dict["public_key"] as? Data, pubKey.count == 32,
              let privKey = dict["private_key"] as? Data, privKey.count == 32 else {
            return nil
        }

        let existingIdentifier = (dict["identifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = existingIdentifier, !id.isEmpty {
            dict["identifier"] = id
        } else {
            let hostId = (dict["host_identifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let hostId = hostId, !hostId.isEmpty {
                dict["identifier"] = hostId
            } else {
                dict["identifier"] = "E77767E6-350D-3A46-AEC3-35E25C75D6DE"
            }
        }

        if dict["alt_irk"] == nil, let peerAltIrk = dict["peer_alt_irk"] as? Data {
            dict["alt_irk"] = peerAltIrk
        }

        return try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    @discardableResult
    static func prepareURL(fileManager: FileManager = .default) -> URL {
        let destination = url
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        // If the user has not explicitly imported a custom pairing file, always ensure
        // the bundled DefaultPairing.plist is synchronized so app updates never get stuck with old sandbox files.
        if !hasUserImportedCustomPairing,
           let bundledURL = Bundle.main.url(forResource: "DefaultPairing", withExtension: "plist"),
           fileManager.fileExists(atPath: bundledURL.path),
           let bundledData = try? Data(contentsOf: bundledURL),
           let normalizedBundled = normalizePairingData(bundledData) ?? (isValidIdevicePairing(at: bundledURL, fileManager: fileManager) ? bundledData : nil) {
            try? normalizedBundled.write(to: destination, options: .atomic)
            protectPairingFile(at: destination, fileManager: fileManager)
            removeLegacyCopies(fileManager: fileManager)
            return destination
        }

        if fileManager.fileExists(atPath: destination.path) {
            if isValidIdevicePairing(at: destination, fileManager: fileManager) {
                removeLegacyCopies(fileManager: fileManager)
                return destination
            }

            var healed = false
            if let existingData = try? Data(contentsOf: destination),
               let normalized = normalizePairingData(existingData) {
                if (try? normalized.write(to: destination, options: .atomic)) != nil {
                    protectPairingFile(at: destination, fileManager: fileManager)
                    if isValidIdevicePairing(at: destination, fileManager: fileManager) {
                        healed = true
                    }
                }
            }

            if !healed {
                if let bundledURL = Bundle.main.url(forResource: "DefaultPairing", withExtension: "plist"),
                   fileManager.fileExists(atPath: bundledURL.path),
                   let bundledData = try? Data(contentsOf: bundledURL),
                   let normalizedBundled = normalizePairingData(bundledData) ?? (isValidIdevicePairing(at: bundledURL, fileManager: fileManager) ? bundledData : nil) {
                    try? normalizedBundled.write(to: destination, options: .atomic)
                    protectPairingFile(at: destination, fileManager: fileManager)
                }
            }

            removeLegacyCopies(fileManager: fileManager)
            return destination
        }

        migrateLegacyCopy(to: destination, fileManager: fileManager)

        if fileManager.fileExists(atPath: destination.path) {
            if !isValidIdevicePairing(at: destination, fileManager: fileManager) {
                if let existingData = try? Data(contentsOf: destination),
                   let normalized = normalizePairingData(existingData) {
                    try? normalized.write(to: destination, options: .atomic)
                    protectPairingFile(at: destination, fileManager: fileManager)
                }
            }
        }

        if !fileManager.fileExists(atPath: destination.path) {
            if let bundledURL = Bundle.main.url(forResource: "DefaultPairing", withExtension: "plist"),
               fileManager.fileExists(atPath: bundledURL.path) {
                if let data = try? Data(contentsOf: bundledURL) {
                    let toWrite = normalizePairingData(data) ?? data
                    try? toWrite.write(to: destination, options: .atomic)
                    protectPairingFile(at: destination, fileManager: fileManager)
                }
            }
        }

        removeLegacyCopies(fileManager: fileManager)
        return destination
    }

    static func replace(with sourceURL: URL, fileManager: FileManager = .default) throws {
        hasUserImportedCustomPairing = true
        let destination = prepareURL(fileManager: fileManager)
        let rawData = try Data(contentsOf: sourceURL)
        let dataToWrite = normalizePairingData(rawData) ?? rawData

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        removeLegacyCopies(fileManager: fileManager)
        try dataToWrite.write(to: destination, options: .atomic)
        protectPairingFile(at: destination, fileManager: fileManager)
    }

    static func importFromPicker(_ sourceURL: URL, fileManager: FileManager = .default) throws {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        try replace(with: sourceURL, fileManager: fileManager)
    }

    static func remove(fileManager: FileManager = .default) throws {
        let destination = prepareURL(fileManager: fileManager)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        removeLegacyCopies(fileManager: fileManager)
    }

    static func resetToBundledDefault(fileManager: FileManager = .default) throws {
        hasUserImportedCustomPairing = false
        let destination = url
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        prepareURL(fileManager: fileManager)
    }

    private static var directoryURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pairing", isDirectory: true)
    }

    private static var legacyURLs: [URL] {
        [
            URL.documentsDirectory.appendingPathComponent(fileName),
            URL.documentsDirectory.appendingPathComponent(legacyFileName)
        ]
    }

    private static func migrateLegacyCopy(to destination: URL, fileManager: FileManager) {
        for legacyURL in legacyURLs where fileManager.fileExists(atPath: legacyURL.path) {
            do {
                try fileManager.moveItem(at: legacyURL, to: destination)
            } catch {
                if let data = try? Data(contentsOf: legacyURL) {
                    try? data.write(to: destination, options: .atomic)
                    try? fileManager.removeItem(at: legacyURL)
                }
            }

            protectPairingFile(at: destination, fileManager: fileManager)
            break
        }
    }

    private static func removeLegacyCopies(fileManager: FileManager) {
        for legacyURL in legacyURLs where fileManager.fileExists(atPath: legacyURL.path) {
            try? fileManager.removeItem(at: legacyURL)
        }
    }

    private static func protectPairingFile(at url: URL, fileManager: FileManager) {
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
