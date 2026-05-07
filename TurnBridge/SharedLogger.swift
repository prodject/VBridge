import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

// MARK: - Log Level

public enum LogLevel: Int, Codable, CaseIterable, Comparable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .debug:   return "DEBUG"
        case .info:    return "INFO"
        case .warning: return "WARN"
        case .error:   return "ERROR"
        }
    }

    public var icon: String {
        switch self {
        case .debug:   return "\u{1FAB2}"  // 🪲
        case .info:    return "\u{2139}"    // ℹ
        case .warning: return "\u{26A0}"    // ⚠
        case .error:   return "\u{1F534}"   // 🔴
        }
    }
}

// MARK: - Log Source

public enum LogSource: String, Codable, CaseIterable {
    case app = "APP"
    case tunnel = "TP"
    case wireguard = "WG"

    public var displayName: String {
        switch self {
        case .app:       return "App"
        case .tunnel:    return "Turn Proxy"
        case .wireguard: return "WireGuard"
        }
    }
}

// MARK: - Log Entry

public struct LogEntry: Identifiable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let level: LogLevel
    public let source: LogSource
    public let message: String

    /// Raw line format: `[MM-dd HH:mm:ss] LEVEL|SOURCE|message`
    public var rawLine: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return "[\(formatter.string(from: timestamp))] \(level.label)|\(source.rawValue)|\(message)"
    }

    public var displayLine: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return "\(formatter.string(from: timestamp)) \(level.icon) [\(source.rawValue)] \(message)"
    }

    /// Parse a raw log line back into a LogEntry
    public static func parse(_ line: String) -> LogEntry? {
        guard line.hasPrefix("[") else { return nil }
        guard let closeBracket = line.firstIndex(of: "]") else { return nil }
        let dateString = String(line[line.index(after: line.startIndex)..<closeBracket])
        let afterBracket = line.index(closeBracket, offsetBy: 2, limitedBy: line.endIndex) ?? line.endIndex
        let rest = String(line[afterBracket...])

        let parts = rest.split(separator: "|", maxSplits: 2)
        guard parts.count == 3 else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm:ss"
            let date = formatter.date(from: dateString) ?? Date()
            return LogEntry(id: UUID(), timestamp: date, level: .info, source: inferSource(from: rest), message: rest)
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        let date = formatter.date(from: dateString) ?? Date()
        let level = LogLevel.allCases.first { $0.label == String(parts[0]) } ?? .info
        let source = LogSource.allCases.first { $0.rawValue == String(parts[1]) } ?? .app
        return LogEntry(id: UUID(), timestamp: date, level: level, source: source, message: String(parts[2]))
    }

    private static func inferSource(from message: String) -> LogSource {
        if message.contains("[WG]") { return .wireguard }
        if message.contains("[TP]") { return .tunnel }
        return .app
    }
}

// MARK: - SharedLogger

public struct SharedLogger {

    // MARK: - App Group detection from binary entitlements
    private static let defaultAppGroupID = "group.com.prodject.vbridge"

    private static let _appGroupID: String? = {
        var candidates: [String] = []

        // 1) Try reading App Group from code signature entitlements in the Mach-O binary.
        if let groups = appGroupsFromBinary() {
            candidates.append(contentsOf: groups)
        }

        // 2) Fallback: derive from bundle ID (works for Xcode-signed builds).
        let bundleID = Bundle.main.bundleIdentifier ?? "com.prodject.vbridge"
        let baseBundleID = bundleID.replacingOccurrences(of: ".network-extension", with: "")
        candidates.append("group.\(baseBundleID)")

        // 3) Stable project default fallback.
        candidates.append(defaultAppGroupID)

        for candidate in candidates {
            if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: candidate) != nil {
                return candidate
            }
        }

        // Last resort: keep deterministic fallback instead of nil, so
        // UserDefaults(suiteName:) path remains consistent for debug builds.
        return candidates.first
    }()

    static var appGroupID: String? { _appGroupID }

    private static func appGroupsFromBinary() -> [String]? {
        // Try own executable first
        if let path = Bundle.main.executablePath,
           let groups = extractAppGroups(fromBinaryAt: path) {
            return groups
        }
        // If running as network extension, try the main app binary
        // Extension path: MainApp.app/PlugIns/Extension.appex/Extension
        // Main app path:  MainApp.app/MainApp
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.hasSuffix(".appex") {
            let plugInsDir = (bundlePath as NSString).deletingLastPathComponent
            let appDir = (plugInsDir as NSString).deletingLastPathComponent
            let appName = ((appDir as NSString).lastPathComponent as NSString).deletingPathExtension
            let mainAppPath = (appDir as NSString).appendingPathComponent(appName)
            if let groups = extractAppGroups(fromBinaryAt: mainAppPath) {
                return groups
            }
        }
        return nil
    }

    private static func extractAppGroups(fromBinaryAt path: String) -> [String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }

        let xmlMarker = Data("<?xml".utf8)
        let endMarker = Data("</plist>".utf8)
        let groupsKey = Data("application-groups".utf8)

        guard data.range(of: groupsKey) != nil else { return nil }

        var searchRange = data.startIndex..<data.endIndex
        while let xmlStart = data.range(of: xmlMarker, in: searchRange) {
            guard let xmlEnd = data.range(of: endMarker, in: xmlStart.lowerBound..<data.endIndex) else { break }

            let plistRange = xmlStart.lowerBound..<xmlEnd.upperBound
            let plistData = data.subdata(in: plistRange)

            if let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
               let groups = plist["com.apple.security.application-groups"] as? [String],
               !groups.isEmpty {
                return groups
            }

            searchRange = xmlEnd.upperBound..<data.endIndex
        }
        return nil
    }

    // MARK: - Log file

    static var isAvailable: Bool {
        return logFileURL != nil
    }

    static var logFileURL: URL? {
        guard let groupID = appGroupID else { return nil }
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
        return container?.appendingPathComponent("vpn_tunnel.log")
    }

    private static func normalizedWidgetState(from rawValue: String) -> VBridgeLiveActivityPhase? {
        let lowered = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered.contains("disconnecting") || lowered.contains("disconnected") {
            return .disconnected
        }
        if lowered.contains("reasserting") || lowered.contains("connecting") {
            return .connecting
        }
        if lowered.contains("connected") {
            return .connected
        }
        if lowered.contains("invalid") || lowered.contains("unknown") {
            return .unknown
        }
        return nil
    }

    private static func parseConnectedWorkers(from message: String) -> (Int, Int)? {
        guard let range = message.range(of: "Connected workers ") else { return nil }
        let suffix = message[range.upperBound...]
        let value = suffix.split(separator: " ").first.map(String.init) ?? String(suffix)
        let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let active = Int(parts[0]),
              let total = Int(parts[1]) else {
            return nil
        }
        return (active, total)
    }

    private static func parseRelayIP(from message: String) -> String? {
        guard let range = message.range(of: "relayed-address=") else { return nil }
        let suffix = message[range.upperBound...]
        let value = String(suffix).split(separator: " ").first.map(String.init) ?? String(suffix)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("["),
           let endIndex = trimmed.firstIndex(of: "]") {
            return String(trimmed[trimmed.index(after: trimmed.startIndex)..<endIndex])
        }

        if let lastColon = trimmed.lastIndex(of: ":") {
            let host = String(trimmed[..<lastColon])
            let port = String(trimmed[trimmed.index(after: lastColon)...])
            if !host.isEmpty, !port.isEmpty, port.allSatisfy(\.isNumber) {
                return host
            }
        }

        return trimmed
    }

    public static func updateWidgetLiveState(
        status rawStatus: String? = nil,
        activeConnections: Int? = nil,
        totalConnections: Int? = nil,
        relayIP: String? = nil,
        profileName: String? = nil,
        estimatedRemainingSeconds: Int? = nil
    ) {
        let phase = rawStatus.flatMap(normalizedWidgetState(from:))
        VBridgeLiveActivityStore.update(
            profileName: profileName,
            phase: phase,
            activeConnections: activeConnections,
            totalConnections: totalConnections,
            relayIP: relayIP,
            estimatedRemainingSeconds: estimatedRemainingSeconds
        )
        reloadWidgetTimelinesIfAvailable()
    }

    private static func updateWidgetLiveStateIfNeeded(message: String) {
        var phase: VBridgeLiveActivityPhase?
        if message.contains("VPN status:") {
            let statusValue = message.replacingOccurrences(of: "VPN status:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            phase = normalizedWidgetState(from: statusValue)
        }

        var parsedActiveConnections: Int?
        var parsedTotalConnections: Int?
        if let parsed = parseConnectedWorkers(from: message) {
            parsedActiveConnections = parsed.0
            parsedTotalConnections = parsed.1
        }

        var parsedRelayIP: String?
        if let relayIP = parseRelayIP(from: message) {
            parsedRelayIP = relayIP
        }

        if phase != nil || parsedActiveConnections != nil || parsedTotalConnections != nil || parsedRelayIP != nil {
            VBridgeLiveActivityStore.update(
                phase: phase,
                activeConnections: parsedActiveConnections,
                totalConnections: parsedTotalConnections,
                relayIP: parsedRelayIP
            )
            reloadWidgetTimelinesIfAvailable()
        }
    }

    private static func reloadWidgetTimelinesIfAvailable() {
#if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: "VBridgeWidget")
#endif
    }

    private static let maxLogSize: UInt64 = 500 * 1024
    private static let rotationKeepRatio: Double = 0.6

    // MARK: - Write

    public static func log(_ message: String, level: LogLevel = .info, source: LogSource = .app) {
        guard let url = logFileURL else { return }

        let entry = LogEntry(id: UUID(), timestamp: Date(), level: level, source: source, message: message)
        let logLine = entry.rawLine + "\n"
        guard let data = logLine.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: url.path) {
            if let fileHandle = try? FileHandle(forWritingTo: url) {
                defer { fileHandle.closeFile() }
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
            }
            rotateIfNeeded()
        } else {
            try? data.write(to: url)
        }

        updateWidgetLiveStateIfNeeded(message: message)
    }

    // MARK: - Convenience

    public static func debug(_ message: String, source: LogSource = .app) {
        log(message, level: .debug, source: source)
    }

    public static func info(_ message: String, source: LogSource = .app) {
        log(message, level: .info, source: source)
    }

    public static func warning(_ message: String, source: LogSource = .app) {
        log(message, level: .warning, source: source)
    }

    public static func error(_ message: String, source: LogSource = .app) {
        log(message, level: .error, source: source)
    }

    // MARK: - Read

    public static func readEntries() -> [LogEntry] {
        guard let url = logFileURL,
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return content
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .compactMap { LogEntry.parse($0) }
    }

    public static func readLogs() -> [String] {
        guard let url = logFileURL,
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return content.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    // MARK: - Clear

    public static func clearLogs() {
        guard let url = logFileURL else { return }
        try? "".write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Rotation

    private static func rotateIfNeeded() {
        guard let url = logFileURL else { return }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attrs[.size] as? UInt64,
              fileSize > maxLogSize else { return }

        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let keepCount = Int(Double(lines.count) * rotationKeepRatio)
        let trimmed = Array(lines.suffix(keepCount))
        let newContent = trimmed.joined(separator: "\n") + "\n"
        try? newContent.write(to: url, atomically: true, encoding: .utf8)
    }
}
