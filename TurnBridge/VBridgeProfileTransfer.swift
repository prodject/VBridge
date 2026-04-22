import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct VBridgeAppSettingsSnapshot: Codable, Equatable {
    var excludeAPNs: Bool
    var excludeCellularServices: Bool
    var excludeLocalNetworks: Bool
    var manualCaptcha: Bool
    var autoUpdateEnabled: Bool
    var appTheme: String

    static func current() -> VBridgeAppSettingsSnapshot {
        let defaults = UserDefaults.standard
        return VBridgeAppSettingsSnapshot(
            excludeAPNs: defaults.object(forKey: "excludeAPNs") as? Bool ?? false,
            excludeCellularServices: defaults.object(forKey: "excludeCellularServices") as? Bool ?? false,
            excludeLocalNetworks: defaults.object(forKey: "excludeLocalNetworks") as? Bool ?? true,
            manualCaptcha: defaults.object(forKey: "manualCaptcha") as? Bool ?? false,
            autoUpdateEnabled: defaults.object(forKey: "autoUpdateEnabled") as? Bool ?? true,
            appTheme: defaults.string(forKey: "appTheme") ?? "system"
        )
    }

    func apply() {
        let defaults = UserDefaults.standard
        defaults.set(excludeAPNs, forKey: "excludeAPNs")
        defaults.set(excludeCellularServices, forKey: "excludeCellularServices")
        defaults.set(excludeLocalNetworks, forKey: "excludeLocalNetworks")
        defaults.set(manualCaptcha, forKey: "manualCaptcha")
        defaults.set(autoUpdateEnabled, forKey: "autoUpdateEnabled")
        defaults.set(appTheme, forKey: "appTheme")
    }
}

struct VBridgeProfilePackage: Codable, Equatable {
    var format: String
    var profile: VPNProfile
    var appSettings: VBridgeAppSettingsSnapshot
    var exportedAt: Date?

    static func fromCurrent(profile: VPNProfile) -> VBridgeProfilePackage {
        VBridgeProfilePackage(
            format: "vbridge-profile-v1",
            profile: profile,
            appSettings: .current(),
            exportedAt: Date()
        )
    }

    static func decode(from data: Data) throws -> VBridgeProfilePackage {
        let isoDecoder = JSONDecoder()
        isoDecoder.dateDecodingStrategy = .iso8601
        if let decoded = try? isoDecoder.decode(VBridgeProfilePackage.self, from: data) {
            return decoded
        }

        let plainDecoder = JSONDecoder()
        return try plainDecoder.decode(VBridgeProfilePackage.self, from: data)
    }
}

extension UTType {
    static var vbridgeProfile: UTType {
        UTType(filenameExtension: "vbridge") ?? .json
    }
}

struct VBridgeProfileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.vbridgeProfile, .json, .data] }

    var package: VBridgeProfilePackage

    init(package: VBridgeProfilePackage) {
        self.package = package
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.package = try VBridgeProfilePackage.decode(from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(package)
        return .init(regularFileWithContents: data)
    }
}
