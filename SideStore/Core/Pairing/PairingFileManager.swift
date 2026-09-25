//
//  PairingFileManager.swift
//  SideStore
//
//  Created by Magesh K on 17/06/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import UniformTypeIdentifiers
import MinimuxerCommon

public struct PairingFileMetadata: Sendable {
    public let exists: Bool
    public let size: Int64
    public let creationDate: Date?
    public let modificationDate: Date?
}

final class PairingFileManager: NSObject {
    static let shared = PairingFileManager()

    static var supportedContentTypes: [UTType] {
        var types = AppConstants.Pairing.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        types.append(contentsOf: [.propertyList, .xml])
        return types
    }

    // zh-patch: 解析配对文件内容所属协议 (RP / lockdown)
    private nonisolated static func pairingMode(of contents: String) -> PairingProtocol? {
        guard let parsed = try? PairingFileParser.parse(content: contents, preferred: nil) else { return nil }
        return parsed.mode
    }

    // zh-patch (P6): LC+Sideloadly 场景 — Sideloadly 每次安装会把预信任的 RP 格式配对文件
    // 嵌入包内 (bundle 资源或 Info.plist), 内容随安装刷新。上游新版只读 Documents,
    // 这里保留嵌入文件这一来源: 实时读取不落盘, 避免 Sideloadly 重装后用到旧信任文件。
    nonisolated static func embeddedRPPairingFile() -> String? {
        let fm = FileManager.default
        if let url = Bundle.main.url(forResource: AppConstants.Pairing.bundleResourceName, withExtension: AppConstants.Pairing.bundleResourceFileExtension),
           fm.fileExists(atPath: url.path),
           let data = fm.contents(atPath: url.path),
           let contents = String(data: data, encoding: .utf8), !contents.isEmpty,
           pairingMode(of: contents) == .rppairing
        {
            return contents
        }
        if let plistString = Bundle.main.object(forInfoDictionaryKey: AppConstants.Pairing.bundleResourceName) as? String,
           !plistString.isEmpty, !plistString.contains(AppConstants.Pairing.placeholderString),
           pairingMode(of: plistString) == .rppairing
        {
            return plistString
        }
        return nil
    }

    var activeProtocol: PairingProtocol {
        minimuxerPairingProtocol()
    }

    var persistedActiveProtocol: PairingProtocol? {
        get { UserDefaults.standard.activePairingProtocol }
        set { UserDefaults.standard.activePairingProtocol = newValue }
    }

    var preferredProtocol: PairingProtocol? {
        get { UserDefaults.standard.preferredPairingProtocol }
        set { UserDefaults.standard.preferredPairingProtocol = newValue }
    }

    nonisolated func pairingFileURL(for mode: PairingProtocol) -> URL {
        let fileName = mode == .rppairing ? AppConstants.Pairing.remotePairingFileName : AppConstants.Pairing.lockdownPairingFileName
        return FileManager.default.documentsDirectory.appendingPathComponent(fileName)
    }

    nonisolated func hasPairingFile(for mode: PairingProtocol) -> Bool {
        return FileManager.default.fileExists(atPath: pairingFileURL(for: mode).path)
    }

    nonisolated func hasPairingFile() -> Bool {
        guard !UserDefaults.standard.isPairingReset else {
            // zh-patch: 嵌入 RP 文件无视 isPairingReset 门控 (Sideloadly 每次安装重新生成并预信任)
            return Self.embeddedRPPairingFile() != nil
        }
        if let target = preferredProtocol, hasPairingFile(for: target) {
            return true
        }
        if let mode = persistedActiveProtocol, hasPairingFile(for: mode) {
            return true
        }
        // zh-patch: LC+Sideloadly 场景 Documents 可能没有配对文件, 但包内嵌有可用 RP 文件
        return Self.embeddedRPPairingFile() != nil
    }

    nonisolated func metadata(for mode: PairingProtocol) -> PairingFileMetadata {
        let fileURL = pairingFileURL(for: mode)
        let path = fileURL.path
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            return PairingFileMetadata(exists: false, size: 0, creationDate: nil, modificationDate: nil)
        }
        let attrs = (try? fm.attributesOfItem(atPath: path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let creation = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date)
        let mod = attrs[.modificationDate] as? Date
        return PairingFileMetadata(exists: true, size: size, creationDate: creation, modificationDate: mod)
    }

    nonisolated func fetchPairingFile(for mode: PairingProtocol) -> String? {
        let fileURL = pairingFileURL(for: mode)
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path),
           let contents = try? String(contentsOf: fileURL), !contents.isEmpty
        {
            return contents
        }
        // zh-patch: Documents 无 RP 文件时兜底用包内嵌入的 RP 文件 (Sideloadly 预信任)
        if mode == .rppairing, let contents = Self.embeddedRPPairingFile() {
            debugLog("[PairingFile] zh-patch: Documents RP pairing file missing; using embedded RP-format pairing file")
            return contents
        }
        return nil
    }

    nonisolated func fetchPairingFile(preferred: PairingProtocol? = nil) -> String? {
        guard !UserDefaults.standard.isPairingReset else {
            // zh-patch: 嵌入 RP 文件无视 isPairingReset 门控 (该门控针对手动导入的 lockdown 文件流程)
            if let contents = Self.embeddedRPPairingFile() {
                debugLog("[PairingFile] zh-patch: using embedded RP-format pairing file (bypassing isPairingReset gate)")
                return contents
            }
            return nil
        }
        let targetPreferred = preferred ?? preferredProtocol
        if let targetPreferred, let contents = fetchPairingFile(for: targetPreferred) {
            // zh-patch: iOS 17+ lockdown 直连传输被设备拒收 (连接即断, AFC/instproxy 全断),
            // 嵌入 RP 可用时优先用 RP, 避免进入不可用的 .lockdown 模式
            if #available(iOS 17, *), Self.pairingMode(of: contents) == .lockdown,
               let rp = Self.embeddedRPPairingFile() {
                debugLog("[PairingFile] zh-patch: lockdown pairing selected on iOS 17+; preferring embedded RP-format pairing file")
                return rp
            }
            return contents
        }
        if let persisted = persistedActiveProtocol, let contents = fetchPairingFile(for: persisted) {
            if #available(iOS 17, *), Self.pairingMode(of: contents) == .lockdown,
               let rp = Self.embeddedRPPairingFile() {
                debugLog("[PairingFile] zh-patch: lockdown pairing selected on iOS 17+; preferring embedded RP-format pairing file")
                return rp
            }
            return contents
        }
        // zh-patch: 无任何 Documents 来源时兜底返回嵌入 RP 文件, 保持 LC+Sideloadly 开箱即用
        if let contents = Self.embeddedRPPairingFile() {
            debugLog("[PairingFile] zh-patch: no Documents pairing source; using embedded RP-format pairing file")
            return contents
        }
        return nil
    }

    @discardableResult
    nonisolated func parse(content: String, preferred: PairingProtocol? = nil) throws -> any PairingFile {
        try PairingFileParser.parse(content: content, preferred: preferred)
    }

    @discardableResult
    func savePairingFile(contents: String, preferred: PairingProtocol? = nil) throws -> any PairingFile {
        let parsed = try parse(content: contents, preferred: preferred)
        let destinationURL = pairingFileURL(for: parsed.mode)
        let fm = FileManager.default
        if fm.fileExists(atPath: destinationURL.path) {
            try? fm.removeItem(at: destinationURL)
        }
        try contents.write(to: destinationURL, atomically: true, encoding: .utf8)
        debugLog("[PairingFile] Saved \(parsed.mode.rawValue) pairing file to: \(destinationURL.path)")
        UserDefaults.standard.isPairingReset = false
        return parsed
    }

    func inspectPairingFile(from url: URL) throws -> (content: String, file: any PairingFile) {
        let isSecured = url.startAccessingSecurityScopedResource()
        defer {
            if isSecured {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let data = try Data(contentsOf: url)
        guard let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let parsed = try parse(content: content, preferred: nil)
        return (content, parsed)
    }

    func importPairingFile(from url: URL, preferred: PairingProtocol? = nil) throws {
        let (content, _) = try inspectPairingFile(from: url)
        let parsed = try savePairingFile(contents: content, preferred: preferred)
        persistedActiveProtocol = parsed.mode
    }

    func deletePairingFile(for mode: PairingProtocol) {
        let fileURL = pairingFileURL(for: mode)
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            try? fm.removeItem(at: fileURL)
            debugLog("[PairingFile] Deleted \(mode.rawValue) pairing file: \(fileURL.path)")
        }
        if mode == persistedActiveProtocol {
            persistedActiveProtocol = nil
        }
    }

    func resetAllPairingFiles() {
        let fm = FileManager.default
        let files = [
            AppConstants.Pairing.lockdownPairingFileName,
            AppConstants.Pairing.remotePairingFileName,
            AppConstants.Pairing.legacyPairingFileName
        ]
        for name in files {
            let path = fm.documentsDirectory.appendingPathComponent(name)
            if fm.fileExists(atPath: path.path) {
                try? fm.removeItem(at: path)
            }
        }
        UserDefaults.standard.isPairingReset = true
        persistedActiveProtocol = nil
        debugLog("[PairingFile] Reset all pairing files.")
    }
}
