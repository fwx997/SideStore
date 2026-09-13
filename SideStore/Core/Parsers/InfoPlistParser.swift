//
//  InfoPlistParser.swift
//  SideStore
//
//  Created by Magesh K on 13/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
#if canImport(UIKit)
@preconcurrency import UIKit
#endif

public struct InfoPlistParser: @unchecked Sendable {
    public private(set) var rawDictionary: [String: Any]

    public var dictionary: [String: Any] {
        rawDictionary
    }

    public init(dictionary: [String: Any]) {
        self.rawDictionary = dictionary
    }

    public init(data: Data) throws {
        guard let dict = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw OperationError.invalidApp(reason: "Invalid PropertyList data format.")
        }
        self.rawDictionary = dict
    }

    public init(plistURL: URL) throws {
        let data = try Data(contentsOf: plistURL)
        try self.init(data: data)
    }

    public init(bundleURL: URL) throws {
        let plistURL = bundleURL.appendingPathComponent("Info.plist")
        try self.init(plistURL: plistURL)
    }

    public var bundleIdentifier: String? {
        (rawDictionary["CFBundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var appName: String {
        displayName ?? bundleName ?? "Unknown"
    }

    public var displayName: String? {
        rawDictionary["CFBundleDisplayName"] as? String
    }

    public var bundleName: String? {
        rawDictionary["CFBundleName"] as? String
    }

    public var executableName: String? {
        rawDictionary["CFBundleExecutable"] as? String
    }

    public var shortVersionString: String? {
        rawDictionary["CFBundleShortVersionString"] as? String
    }

    public var buildVersion: String? {
        rawDictionary["CFBundleVersion"] as? String
    }

    public var displayVersion: String {
        let short = shortVersionString
        let build = buildVersion
        if let short = short, let build = build {
            return "\(short) (\(build))"
        }
        return short ?? build ?? "N/A"
    }

    public var minimumOSVersion: String? {
        rawDictionary["MinimumOSVersion"] as? String
    }

    public var isFileSharingEnabled: Bool {
        rawDictionary["UIFileSharingEnabled"] as? Bool ?? false
    }

    public var supportsOpeningDocumentsInPlace: Bool {
        rawDictionary["LSSupportsOpeningDocumentsInPlace"] as? Bool ?? false
    }

    public var backgroundModes: [String] {
        rawDictionary["UIBackgroundModes"] as? [String] ?? []
    }

    public var customURLSchemes: [String] {
        guard let urlTypes = rawDictionary["CFBundleURLTypes"] as? [[String: Any]] else { return [] }
        return urlTypes.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
    }

    public var queriedURLSchemes: [String] {
        rawDictionary["LSApplicationQueriesSchemes"] as? [String] ?? []
    }

    public var privacyPermissions: [String: String] {
        var dict = [String: String]()
        for (key, val) in rawDictionary where key.hasPrefix("NS") && key.hasSuffix("UsageDescription") {
            if let str = val as? String { dict[key] = str }
        }
        return dict
    }

    public mutating func set(value: Any?, for key: String) {
        rawDictionary[key] = value
    }

    public mutating func merge(_ dictionary: [String: Any]) {
        for (key, value) in dictionary {
            rawDictionary[key] = value
        }
    }

    public func toXMLData() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: rawDictionary, format: .xml, options: 0)
    }

    public func toJSONData() throws -> Data {
        try JSONSerialization.data(withJSONObject: rawDictionary, options: [.prettyPrinted, .sortedKeys])
    }

    public func write(to url: URL) throws {
        let data = try toXMLData()
        try data.write(to: url, options: .atomic)
    }

    public static func sanitizeBundleID(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        var sanitized = raw.unicodeScalars.filter { allowed.contains($0) }.map(String.init).joined()
        while sanitized.contains("..") {
            sanitized = sanitized.replacingOccurrences(of: "..", with: ".")
        }
        return sanitized.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
    }
}

#if canImport(UIKit)
extension InfoPlistParser {
    @MainActor
    public static func shouldChangeBundleID(
        in textField: UITextField,
        range: NSRange,
        replacementString string: String,
        suffix: String = "",
        isSuffixEnforced: Bool = false,
        onTextUpdated: ((String) -> Void)? = nil
    ) -> Bool {
        guard let currentText = textField.text as NSString? else { return true }

        let suffixLength = (isSuffixEnforced && !suffix.isEmpty) ? (suffix as NSString).length : 0
        let suffixStartIndex = currentText.length - suffixLength
        verboseLog("[InfoPlistParser] shouldChange: current='\(currentText)', range=\(range), string='\(string)', suffix='\(suffix)', isSuffixEnforced=\(isSuffixEnforced), suffixStartIndex=\(suffixStartIndex)")
        guard suffixStartIndex >= 0 else { return true }

        // Full replacement (e.g. Select All + paste or type)
        if range.location == 0 && range.length == currentText.length {
            let cleanBase = sanitizeBundleID(string)
            let finalString = isSuffixEnforced && !suffix.isEmpty
                ? (cleanBase.hasSuffix(suffix) ? cleanBase : cleanBase + suffix)
                : cleanBase
            textField.text = finalString
            onTextUpdated?(finalString)
            return false
        }

        // Drop any keystroke that touches or encroaches on the persistent suffix
        if isSuffixEnforced && !suffix.isEmpty && range.location + range.length > suffixStartIndex {
            return false
        }

        // Allowed characters for Apple bundle identifier: alphanumeric, hyphen, period
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        if !string.isEmpty && string.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return false
        }

        // Prevent typing or inserting consecutive dots
        if string.contains("..") {
            return false
        }
        if string.hasPrefix(".") && range.location == 0 {
            return false
        }
        if string.hasPrefix(".") && range.location > 0 {
            let prevChar = currentText.substring(with: NSRange(location: range.location - 1, length: 1))
            if prevChar == "." {
                return false
            }
        }
        if string.hasSuffix(".") && range.location + range.length < currentText.length {
            let nextChar = currentText.substring(with: NSRange(location: range.location + range.length, length: 1))
            if nextChar == "." {
                return false
            }
        }

        return true
    }
}
#endif
