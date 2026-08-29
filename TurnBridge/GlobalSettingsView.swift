import SwiftUI
import Foundation
import Darwin
import Network
import UniformTypeIdentifiers
import NetworkExtension

struct TrustedWiFiSettings: Equatable {
    var enabled: Bool
    var ssids: [String]
}

enum TrustedWiFiStorage {
    static let enabledKey = "trustedWiFi.enabled"
    static let ssidsKey = "trustedWiFi.ssids"

    static func load() -> TrustedWiFiSettings {
        let defaults = UserDefaults.standard
        let enabled = defaults.bool(forKey: enabledKey)
        let ssids = normalizedSSIDs(defaults.stringArray(forKey: ssidsKey) ?? [])
        return TrustedWiFiSettings(enabled: enabled, ssids: ssids)
    }

    static func save(_ settings: TrustedWiFiSettings) {
        let defaults = UserDefaults.standard
        defaults.set(settings.enabled, forKey: enabledKey)
        defaults.set(normalizedSSIDs(settings.ssids), forKey: ssidsKey)
    }

    static func summary(_ settings: TrustedWiFiSettings) -> String {
        let count = normalizedSSIDs(settings.ssids).count
        if count == 0 {
            return "No trusted Wi-Fi networks"
        }
        return count == 1 ? "1 trusted Wi-Fi network" : "\(count) trusted Wi-Fi networks"
    }

    static func normalizedSSIDs(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }
}

enum SplitTunnelMode: String, CaseIterable, Codable {
    case direct
    case tunnel

    var title: String {
        switch self {
        case .direct:
            return "Open domains and IPs directly"
        case .tunnel:
            return "Open domains and IPs through tunnel"
        }
    }

    var summary: String {
        switch self {
        case .direct:
            return "Matched traffic bypasses the VPN tunnel."
        case .tunnel:
            return "Only matched traffic goes through the VPN tunnel."
        }
    }
}

struct SplitTunnelSettings: Equatable {
    var enabled: Bool
    var mode: SplitTunnelMode
    var rules: [String]
}

enum SplitTunnelStorage {
    static let enabledKey = "splitTunnelEnabled"
    static let modeKey = "splitTunnelMode"
    static let rulesKey = "splitTunnelRules"
    static let selectedProfileIDKey = "selectedProfileID"
    static let createListURL = "https://iplist.opencck.org/"
    static let githubCIDRSourceKey = "splitTunnelSource.githubCIDR"
    static let githubIPSourceKey = "splitTunnelSource.githubIP"
    static let githubDomainSourceKey = "splitTunnelSource.githubDomain"
    static let githubCIDRRawURL = "https://raw.githubusercontent.com/hxehex/russia-mobile-internet-whitelist/main/cidrwhitelist.txt"
    static let githubIPRawURL = "https://raw.githubusercontent.com/hxehex/russia-mobile-internet-whitelist/main/ipwhitelist.txt"
    static let githubDomainRawURL = "https://raw.githubusercontent.com/hxehex/russia-mobile-internet-whitelist/main/whitelist.txt"

    private struct Metadata: Codable {
        var enabled: Bool
        var mode: SplitTunnelMode
        var ruleCount: Int
    }

    private static let metadataFileName = "split-tunnel-metadata.json"
    private static let rulesFileName = "split-tunnel-rules.txt"
    private static let migrationLock = NSLock()

    static func currentProfileID() -> UUID? {
        guard let rawValue = UserDefaults.standard.string(forKey: selectedProfileIDKey) else { return nil }
        return UUID(uuidString: rawValue)
    }

    static func load(profileID: UUID? = currentProfileID()) -> SplitTunnelSettings {
        ensureStorageDirectoryExists()
        migrateLegacyStorageIfNeeded(selectedProfileID: profileID)
        let metadata = loadMetadata(profileID: profileID)
        return SplitTunnelSettings(
            enabled: metadata.enabled,
            mode: metadata.mode,
            rules: loadRules(from: rulesFileURL(profileID: profileID))
        )
    }

    static func save(_ settings: SplitTunnelSettings, profileID: UUID? = currentProfileID()) {
        let normalizedRules = deduplicatedRules(settings.rules)
        writeRules(normalizedRules, to: rulesFileURL(profileID: profileID))
        writeMetadata(Metadata(enabled: settings.enabled, mode: settings.mode, ruleCount: normalizedRules.count), profileID: profileID)
    }

    static func saveConfiguration(_ settings: SplitTunnelSettings, profileID: UUID? = currentProfileID()) {
        writeMetadata(Metadata(enabled: settings.enabled, mode: settings.mode, ruleCount: settings.rules.count), profileID: profileID)
    }

    static func ruleCountSummary(profileID: UUID? = currentProfileID()) -> String {
        let count = loadMetadata(profileID: profileID).ruleCount
        return count == 1 ? "1 rule" : "\(count) rules"
    }

    static func ruleCountSummary(_ settings: SplitTunnelSettings) -> String {
        let count = settings.rules.count
        return count == 1 ? "1 rule" : "\(count) rules"
    }

    static func exportedText(from settings: SplitTunnelSettings) -> String {
        deduplicatedRules(settings.rules).joined(separator: "\n")
    }

    static func exportURL(for settings: SplitTunnelSettings, profileID: UUID? = currentProfileID()) -> URL {
        let suffix = profileID?.uuidString.prefix(8) ?? "default"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vbridge-routing-\(suffix).txt")
        let text = exportedText(from: settings)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func merge(_ incomingRules: [String], into settings: inout SplitTunnelSettings, profileID: UUID? = currentProfileID()) {
        settings.rules = deduplicatedRules(settings.rules + incomingRules)
        save(settings, profileID: profileID)
    }

    static func replaceRules(
        fromSource sourceKey: String,
        with incomingRules: [String],
        into settings: inout SplitTunnelSettings,
        profileID: UUID? = currentProfileID()
    ) {
        let sourceURL = sourceRulesFileURL(for: sourceKey, profileID: profileID)
        let previousRules = loadRules(from: sourceURL)
        let previousRuleSet = Set(deduplicatedRules(previousRules))
        let filteredExisting = settings.rules.filter { !previousRuleSet.contains($0) }
        let normalizedIncoming = deduplicatedRules(incomingRules)

        settings.rules = deduplicatedRules(filteredExisting + normalizedIncoming)
        save(settings, profileID: profileID)
        writeRules(normalizedIncoming, to: sourceURL)
    }

    static func removeRule(at offsets: IndexSet, from settings: inout SplitTunnelSettings, profileID: UUID? = currentProfileID()) {
        settings.rules.remove(atOffsets: offsets)
        save(settings, profileID: profileID)
    }

    static func clearRules(from settings: inout SplitTunnelSettings, profileID: UUID? = currentProfileID()) {
        settings.rules.removeAll()
        save(settings, profileID: profileID)
    }

    static func addRule(_ rawValue: String, to settings: inout SplitTunnelSettings, profileID: UUID? = currentProfileID()) throws {
        guard let normalized = normalizedRule(rawValue) else {
            throw SplitTunnelValidationError.invalidRule
        }
        merge([normalized], into: &settings, profileID: profileID)
    }

    static func rules(fromFileURL url: URL) throws -> [String] {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            throw SplitTunnelValidationError.unreadableFile
        }
        return try rules(fromRawText: text)
    }

    static func rules(fromRemoteURLString rawURL: String) async throws -> [String] {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw SplitTunnelValidationError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("text/plain, text/*;q=0.9, */*;q=0.1", forHTTPHeaderField: "Accept")
        request.setValue("VBridge/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SplitTunnelValidationError.downloadFailed
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            throw SplitTunnelValidationError.downloadFailed
        }
        return try rules(fromRawText: text)
    }

    static func rules(fromRawText text: String) throws -> [String] {
        let separators = CharacterSet.newlines.union(CharacterSet(charactersIn: ","))
        let lines = text.replacingOccurrences(of: "\r", with: "\n").components(separatedBy: separators)
        let normalized = lines.compactMap(normalizedRule)
        guard !normalized.isEmpty else {
            throw SplitTunnelValidationError.noValidRules
        }
        return deduplicatedRules(normalized)
    }

    nonisolated static func normalizedRule(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.hasPrefix("#"), !trimmed.hasPrefix("//"), !trimmed.hasPrefix(";") else { return nil }

        if let normalizedIP = normalizedIPAddressRule(trimmed) {
            return normalizedIP
        }

        if let normalizedRange = normalizedIPv4RangeRule(trimmed) {
            return normalizedRange
        }

        if let normalizedURL = normalizedURLRule(trimmed) {
            return normalizedURL
        }

        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("*.") {
            let suffix = String(lowered.dropFirst(2))
            return isValidWildcardSuffix(suffix) ? "*.\(suffix)" : nil
        }

        return isValidDomain(lowered) ? lowered : nil
    }

    private static func normalizedIPAddressRule(_ rawValue: String) -> String? {
        let parts = rawValue.split(separator: "/", maxSplits: 1).map(String.init)
        guard let address = parts.first else { return nil }

        if let ipv4 = IPv4Address(address) {
            if parts.count == 1 {
                return "\(ipv4)"
            }
            guard let prefix = Int(parts[1]), (0...32).contains(prefix) else { return nil }
            return "\(ipv4)/\(prefix)"
        }

        if let ipv6 = IPv6Address(address) {
            if parts.count == 1 {
                return "\(ipv6)"
            }
            guard let prefix = Int(parts[1]), (0...128).contains(prefix) else { return nil }
            return "\(ipv6)/\(prefix)"
        }

        return nil
    }

    private static func normalizedIPv4RangeRule(_ rawValue: String) -> String? {
        let cleaned = rawValue.replacingOccurrences(of: " ", with: "")
        let separators = ["-", "–", "—"]

        for separator in separators where cleaned.contains(separator) {
            let parts = cleaned.components(separatedBy: separator)
            guard parts.count == 2,
                  let start = IPv4Address(parts[0]),
                  let end = IPv4Address(parts[1]) else {
                return nil
            }

            let startValue = ipv4NumericValue(start)
            let endValue = ipv4NumericValue(end)
            guard startValue <= endValue else { return nil }
            return "\(start)-\(end)"
        }

        return nil
    }

    private static func normalizedURLRule(_ rawValue: String) -> String? {
        guard let components = URLComponents(string: rawValue),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host?.lowercased() else {
            return nil
        }

        guard isValidDomain(host) || IPv4Address(host) != nil || IPv6Address(host) != nil else {
            return nil
        }

        var normalized = "\(scheme)://\(host)"
        if let port = components.port {
            normalized += ":\(port)"
        }
        if let path = components.percentEncodedPath.isEmpty ? nil : components.percentEncodedPath {
            normalized += path
        }
        if let query = components.percentEncodedQuery, !query.isEmpty {
            normalized += "?\(query)"
        }
        return normalized
    }

    private static func isValidDomain(_ value: String) -> Bool {
        guard value.contains("."), !value.hasPrefix("."), !value.hasSuffix(".") else {
            return false
        }

        let labels = value.split(separator: ".")
        guard labels.count >= 2 else { return false }

        for label in labels {
            guard !label.isEmpty, label.count <= 63 else { return false }
            guard label.first != "-", label.last != "-" else { return false }
            let isValid = label.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-"
            }
            guard isValid else { return false }
        }

        return true
    }

    private static func isValidWildcardSuffix(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("."), !value.hasSuffix(".") else {
            return false
        }

        let labels = value.split(separator: ".")
        guard !labels.isEmpty else { return false }

        for label in labels {
            guard !label.isEmpty, label.count <= 63 else { return false }
            guard label.first != "-", label.last != "-" else { return false }
            let isValid = label.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-"
            }
            guard isValid else { return false }
        }

        return true
    }

    private static func deduplicatedRules(_ rules: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for rule in rules {
            guard let normalized = normalizedRule(rule), !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            result.append(normalized)
        }
        return result
    }

    static func migrateLegacyStorageIfNeeded(selectedProfileID: UUID? = currentProfileID()) {
        migrationLock.lock()
        defer { migrationLock.unlock() }
        guard let selectedProfileID else { return }
        guard !FileManager.default.fileExists(atPath: metadataFileURL(profileID: selectedProfileID).path) else { return }

        let sharedDefaults = SharedLogger.appGroupID.flatMap { UserDefaults(suiteName: $0) }
        let candidates = [sharedDefaults, UserDefaults.standard].compactMap { $0 }
        let source = candidates.first {
            $0.object(forKey: enabledKey) != nil ||
            $0.object(forKey: modeKey) != nil ||
            $0.object(forKey: rulesKey) != nil
        }

        let enabled = source?.object(forKey: enabledKey) as? Bool ?? false
        let mode = SplitTunnelMode(rawValue: source?.string(forKey: modeKey) ?? "") ?? .direct
        let rules = source?.stringArray(forKey: rulesKey) ?? []
        writeRules(rules, to: rulesFileURL(profileID: selectedProfileID))
        writeMetadata(Metadata(enabled: enabled, mode: mode, ruleCount: rules.count), profileID: selectedProfileID)

        for sourceKey in [githubCIDRSourceKey, githubIPSourceKey, githubDomainSourceKey] {
            let sourceRules = source?.stringArray(forKey: sourceKey) ?? []
            if !sourceRules.isEmpty {
                writeRules(sourceRules, to: sourceRulesFileURL(for: sourceKey, profileID: selectedProfileID))
            }
        }

        let obsoleteKeys = [enabledKey, modeKey, rulesKey, githubCIDRSourceKey, githubIPSourceKey, githubDomainSourceKey]
        for defaults in candidates {
            for key in obsoleteKeys {
                defaults.removeObject(forKey: key)
            }
            defaults.synchronize()
        }
    }

    private static func storageDirectoryURL() -> URL {
        if let groupID = SharedLogger.appGroupID,
           let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            return container
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private static func ensureStorageDirectoryExists() {
        try? FileManager.default.createDirectory(
            at: storageDirectoryURL(),
            withIntermediateDirectories: true
        )
    }

    private static func profileStorageDirectoryURL(profileID: UUID?) -> URL {
        let base = storageDirectoryURL().appendingPathComponent("routing-profiles", isDirectory: true)
        guard let profileID else { return base.appendingPathComponent("default", isDirectory: true) }
        return base.appendingPathComponent(profileID.uuidString.lowercased(), isDirectory: true)
    }

    private static func metadataFileURL(profileID: UUID?) -> URL {
        profileStorageDirectoryURL(profileID: profileID).appendingPathComponent(metadataFileName)
    }

    private static func rulesFileURL(profileID: UUID?) -> URL {
        profileStorageDirectoryURL(profileID: profileID).appendingPathComponent(rulesFileName)
    }

    private static func sourceRulesFileURL(for sourceKey: String, profileID: UUID?) -> URL {
        let name: String
        switch sourceKey {
        case githubCIDRSourceKey: name = "split-tunnel-source-cidr.txt"
        case githubIPSourceKey: name = "split-tunnel-source-ip.txt"
        case githubDomainSourceKey: name = "split-tunnel-source-domain.txt"
        default: name = "split-tunnel-source-custom.txt"
        }
        return profileStorageDirectoryURL(profileID: profileID).appendingPathComponent(name)
    }

    private static func loadMetadata(profileID: UUID?) -> Metadata {
        guard let data = try? Data(contentsOf: metadataFileURL(profileID: profileID)),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data) else {
            return Metadata(enabled: false, mode: .direct, ruleCount: 0)
        }
        return metadata
    }

    private static func writeMetadata(_ metadata: Metadata, profileID: UUID?) {
        ensureStorageDirectoryExists()
        try? FileManager.default.createDirectory(at: profileStorageDirectoryURL(profileID: profileID), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        try? data.write(to: metadataFileURL(profileID: profileID), options: .atomic)
    }

    private static func loadRules(from url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { return [] }
        return text.components(separatedBy: .newlines).filter { !$0.isEmpty }
    }

    private static func writeRules(_ rules: [String], to url: URL) {
        ensureStorageDirectoryExists()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = rules.joined(separator: "\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func ipv4NumericValue(_ address: IPv4Address) -> UInt32 {
        address.rawValue.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

enum SplitTunnelValidationError: LocalizedError {
    case invalidRule
    case invalidURL
    case unreadableFile
    case downloadFailed
    case noValidRules

    var errorDescription: String? {
        switch self {
        case .invalidRule:
            return "Invalid rule. Supported formats: `*.domain`, `example.com`, `IP`, `IP/MASK`, `IP-IP`, `https://host/path`."
        case .invalidURL:
            return "Enter a valid http or https URL."
        case .unreadableFile:
            return "Unable to read the selected file."
        case .downloadFailed:
            return "Unable to download the remote list."
        case .noValidRules:
            return "No valid split-tunneling rules were found."
        }
    }
}

struct SplitTunnelSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let profileID: UUID?
    let showsDoneButton: Bool
    var onCommit: ((SplitTunnelSettings) -> Void)? = nil

    @State private var settings: SplitTunnelSettings
    @State private var isPullingGitHubList = false
    @State private var errorMessage = ""
    @State private var showErrorAlert = false

    init(
        profileID: UUID? = SplitTunnelStorage.currentProfileID(),
        showsDoneButton: Bool = false,
        onCommit: ((SplitTunnelSettings) -> Void)? = nil
    ) {
        self.profileID = profileID
        self.showsDoneButton = showsDoneButton
        self.onCommit = onCommit
        _settings = State(initialValue: SplitTunnelStorage.load(profileID: profileID))
    }

    var body: some View {
        Form {
            Section(header: Text("Split Tunneling")) {
                Toggle(isOn: enabledBinding) {
                    VStack(alignment: .leading) {
                        Text("Enabled")
                        Text(settings.enabled ? "Matched traffic follows the selected split rule." : "When disabled, all traffic continues through VPN as before.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Picker("Mode", selection: modeBinding) {
                    ForEach(SplitTunnelMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                        Text(settings.mode.summary)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    Text("Domains and URL hosts are resolved to IPs when the tunnel starts. IPv4 ranges are expanded into route blocks automatically.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 2)

                NavigationLink(destination: SplitTunnelRuleListView(settings: $settings, profileID: profileID)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Open List")
                        Text(SplitTunnelStorage.ruleCountSummary(settings))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section(header: Text("Create")) {
                Button(action: {
                    openCreateSite()
                }) {
                    VStack(alignment: .leading) {
                        Text("Create new list on opencck.org")
                        Text(SplitTunnelStorage.createListURL)
                            .font(.caption2.monospaced())
                            .foregroundColor(.secondary)
                    }
                }

                Button(action: {
                    pullGitHubList(
                        sourceKey: SplitTunnelStorage.githubCIDRSourceKey,
                        urlString: SplitTunnelStorage.githubCIDRRawURL
                    )
                }) {
                    VStack(alignment: .leading) {
                        Text("Pull CIDR whitelist from GitHub")
                        Text("github.com/hxehex/russia-mobile-internet-whitelist")
                            .font(.caption2.monospaced())
                            .foregroundColor(.secondary)
                    }
                }
                .disabled(isPullingGitHubList)

                Button(action: {
                    pullGitHubList(
                        sourceKey: SplitTunnelStorage.githubIPSourceKey,
                        urlString: SplitTunnelStorage.githubIPRawURL
                    )
                }) {
                    VStack(alignment: .leading) {
                        Text("Pull individual IP whitelist from GitHub")
                        Text("Large list; use only when exact host routes are required")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("github.com/hxehex/russia-mobile-internet-whitelist")
                            .font(.caption2.monospaced())
                            .foregroundColor(.secondary)
                    }
                }
                .disabled(isPullingGitHubList)

                Button(action: {
                    pullGitHubList(
                        sourceKey: SplitTunnelStorage.githubDomainSourceKey,
                        urlString: SplitTunnelStorage.githubDomainRawURL
                    )
                }) {
                    VStack(alignment: .leading) {
                        Text("Pull domain whitelist from GitHub")
                        Text("github.com/hxehex/russia-mobile-internet-whitelist")
                            .font(.caption2.monospaced())
                            .foregroundColor(.secondary)
                    }
                }
                .disabled(isPullingGitHubList)

                if isPullingGitHubList {
                    HStack(spacing: 10) {
                        ProgressView()
                            .progressViewStyle(.circular)
                        Text("Pulling GitHub list...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section(header: Text("Formats")) {
                Text("Supported masks: exact domains, `*.domain`, `IP`, `IP/MASK`, `IPv4-IPv4`, `http://...`, `https://...`.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Split-Tunneling")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .alert("Split-Tunneling", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .onDisappear {
            onCommit?(settings)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { settings.enabled },
            set: { newValue in
                settings.enabled = newValue
                SplitTunnelStorage.saveConfiguration(settings, profileID: profileID)
            }
        )
    }

    private var modeBinding: Binding<SplitTunnelMode> {
        Binding(
            get: { settings.mode },
            set: { newValue in
                settings.mode = newValue
                SplitTunnelStorage.saveConfiguration(settings, profileID: profileID)
            }
        )
    }

    private func openCreateSite() {
        guard let url = URL(string: SplitTunnelStorage.createListURL) else {
            errorMessage = "Unable to open opencck.org."
            showErrorAlert = true
            return
        }
        openURL(url)
    }

    private func pullGitHubList(sourceKey: String, urlString: String) {
        isPullingGitHubList = true
        Task {
            do {
                let rules = try await SplitTunnelStorage.rules(fromRemoteURLString: urlString)
                await MainActor.run {
                    SplitTunnelStorage.replaceRules(fromSource: sourceKey, with: rules, into: &settings, profileID: profileID)
                    isPullingGitHubList = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    showErrorAlert = true
                    isPullingGitHubList = false
                }
            }
        }
    }
}

struct TrustedWiFiSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var settings = TrustedWiFiStorage.load()
    @State private var showAddSSIDPrompt = false
    @State private var newSSIDText = ""

    let onCommit: ((TrustedWiFiSettings) -> Void)?

    init(onCommit: ((TrustedWiFiSettings) -> Void)? = nil) {
        self.onCommit = onCommit
    }

    var body: some View {
        List {
            Section(header: Text("Trusted Wi-Fi")) {
                Toggle(isOn: enabledBinding) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enabled")
                        Text("When the device joins a trusted SSID, the VPN can stay disconnected and internet goes directly. Outside trusted Wi-Fi, on-demand rules reconnect the VPN automatically.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(TrustedWiFiStorage.summary(settings))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Add exact SSID names manually. These rules are applied through the system VPN manager.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 2)
            }

            if settings.ssids.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No trusted SSIDs yet")
                            .font(.headline)
                        Text("Add the Wi-Fi names where VBridge should stand by and let traffic go directly instead of keeping the VPN active.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                }
            } else {
                Section(header: Text("SSIDs")) {
                    ForEach(settings.ssids, id: \.self) { ssid in
                        Text(ssid)
                            .font(.body)
                    }
                    .onDelete(perform: deleteSSIDs)
                }
            }
        }
        .navigationTitle("Trusted Wi-Fi")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button(action: {
                    newSSIDText = ""
                    showAddSSIDPrompt = true
                }) {
                    Image(systemName: "plus")
                }

                Button("Done") {
                    dismiss()
                }
            }
        }
        .alert("Add Trusted SSID", isPresented: $showAddSSIDPrompt) {
            TextField("Home Wi-Fi", text: $newSSIDText)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            Button("Cancel", role: .cancel) {}
            Button("Add") {
                addSSID(newSSIDText)
            }
        } message: {
            Text("Enter the exact Wi-Fi network name (SSID).")
        }
        .onDisappear {
            onCommit?(settings)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { settings.enabled },
            set: { newValue in
                settings.enabled = newValue
                TrustedWiFiStorage.save(settings)
            }
        )
    }

    private func addSSID(_ value: String) {
        settings.ssids = TrustedWiFiStorage.normalizedSSIDs(settings.ssids + [value])
        TrustedWiFiStorage.save(settings)
    }

    private func deleteSSIDs(at offsets: IndexSet) {
        settings.ssids.remove(atOffsets: offsets)
        TrustedWiFiStorage.save(settings)
    }
}

private struct SplitTunnelRuleListView: View {
    @Binding var settings: SplitTunnelSettings
    let profileID: UUID?

    @State private var showAddRulePrompt = false
    @State private var newRuleText = ""
    @State private var showURLImportPrompt = false
    @State private var importURLText = ""
    @State private var showFileImporter = false
    @State private var isImportingRemoteList = false
    @State private var errorMessage = ""
    @State private var showErrorAlert = false
    @State private var showClearConfirmation = false

    private let importFileTypes: [UTType] = [.plainText, .text]

    var body: some View {
        List {
            if settings.rules.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No split-tunneling rules yet")
                            .font(.headline)
                        Text("Add domains, URL hosts, IPs, CIDR ranges, or IPv4 ranges. Imported lists are merged into this profile's routing set.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                }
            } else {
                Section(header: Text("Rules")) {
                    ForEach(settings.rules, id: \.self) { rule in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(rule)
                                .font(.system(.body, design: isIPAddressRule(rule) ? .monospaced : .default))
                            Text(ruleDescription(rule))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete(perform: deleteRules)
                }
            }

            Section(header: Text("Import")) {
                Button("Import from file") {
                    showFileImporter = true
                }

                Button("Import from URL") {
                    importURLText = ""
                    showURLImportPrompt = true
                }
                .disabled(isImportingRemoteList)

                if isImportingRemoteList {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Downloading remote list...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Split List")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button(action: {
                    newRuleText = ""
                    showAddRulePrompt = true
                }) {
                    Image(systemName: "plus")
                }

                Menu {
                    Button("Import from file") {
                        showFileImporter = true
                    }
                    Button("Import from URL") {
                        importURLText = ""
                        showURLImportPrompt = true
                    }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }

                ShareLink(item: SplitTunnelStorage.exportURL(for: settings, profileID: profileID)) {
                    Image(systemName: "square.and.arrow.up")
                }

                if !settings.rules.isEmpty {
                    Button(role: .destructive, action: {
                        showClearConfirmation = true
                    }) {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .alert("Add Rule", isPresented: $showAddRulePrompt) {
            TextField("*.example.com or 1.2.3.0/24", text: $newRuleText)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            Button("Cancel", role: .cancel) {}
            Button("Add") {
                do {
                    try SplitTunnelStorage.addRule(newRuleText, to: &settings, profileID: profileID)
                } catch {
                    show(error)
                }
            }
        } message: {
            Text("Supported formats: exact domains, `*.domain`, `IP`, `IP/MASK`, `IPv4-IPv4`, `https://host/path`.")
        }
        .alert("Import from URL", isPresented: $showURLImportPrompt) {
            TextField("https://example.com/list.txt", text: $importURLText)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            Button("Cancel", role: .cancel) {}
            Button("Import") {
                importFromRemoteURL(importURLText)
            }
        }
        .alert("Split-Tunneling", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .alert("Clear List?", isPresented: $showClearConfirmation) {
            Button("Clear", role: .destructive) {
                SplitTunnelStorage.clearRules(from: &settings, profileID: profileID)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All split-tunneling rules will be removed.")
        }
        .sheet(isPresented: $showFileImporter) {
            DocumentPicker(
                contentTypes: importFileTypes,
                onPick: { url in
                    showFileImporter = false
                    importFromFile(url)
                },
                onCancel: {
                    showFileImporter = false
                }
            )
            .ignoresSafeArea()
        }
    }

    private func importFromFile(_ url: URL) {
        do {
            let rules = try SplitTunnelStorage.rules(fromFileURL: url)
            SplitTunnelStorage.merge(rules, into: &settings, profileID: profileID)
        } catch {
            show(error)
        }
    }

    private func importFromRemoteURL(_ rawURL: String) {
        isImportingRemoteList = true
        Task {
            do {
                let rules = try await SplitTunnelStorage.rules(fromRemoteURLString: rawURL)
                await MainActor.run {
                    SplitTunnelStorage.merge(rules, into: &settings, profileID: profileID)
                    isImportingRemoteList = false
                }
            } catch {
                await MainActor.run {
                    show(error)
                    isImportingRemoteList = false
                }
            }
        }
    }

    private func deleteRules(at offsets: IndexSet) {
        SplitTunnelStorage.removeRule(at: offsets, from: &settings, profileID: profileID)
    }

    private func show(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        showErrorAlert = true
    }

    private func isIPAddressRule(_ rule: String) -> Bool {
        rule.contains("/") || rule.contains("-") || IPv4Address(rule) != nil || IPv6Address(rule) != nil
    }

    private func ruleDescription(_ rule: String) -> String {
        if rule.hasPrefix("*.") {
            return "Wildcard domain suffix"
        }
        if rule.lowercased().hasPrefix("http://") || rule.lowercased().hasPrefix("https://") {
            return "URL host rule"
        }
        if IPv4Address(rule) != nil || IPv6Address(rule) != nil {
            return "Single IP address"
        }
        if rule.contains("-") {
            return "IPv4 address range"
        }
        if rule.contains("/") {
            return "IP network range"
        }
        return "Exact domain"
    }
}

struct GlobalSettingsView: View {
    @AppStorage("excludeAPNs") private var excludeAPNs = false
    @AppStorage("excludeCellularServices") private var excludeCellularServices = false
    @AppStorage("excludeLocalNetworks") private var excludeLocalNetworks = true
    @AppStorage("manualCaptcha") private var manualCaptcha = false
    @AppStorage("showCaptchaFallbackURL") private var showCaptchaFallbackURL = false
    @AppStorage("autoUpdateEnabled") private var autoUpdateEnabled = true
    @AppStorage("appTheme") private var appTheme = "system"
    @AppStorage("tetherProxyEnabled") private var tetherProxyEnabled = false
    @AppStorage("tetherProxyPort") private var tetherProxyPort = 9000
    @State private var trustedWiFiSummary = TrustedWiFiStorage.summary(TrustedWiFiStorage.load())
    @State private var showVKAuthorization = false
    @State private var vkAuthorizationStatus = VKAuthSessionStore.loadAccessToken() == nil ? "No saved VK sessions" : "VK session saved"

    var body: some View {
        Form {
            Section(header: Text("General")) {
                NavigationLink(destination: AboutView()) {
                    Label(
                        title: { Text("About") },
                        icon: { Image(systemName: "info.circle").foregroundColor(.secondary) }
                    )
                }

                NavigationLink(destination: LogView()) {
                    Label(
                        title: { Text("Logs") },
                        icon: { Image(systemName: "doc.text.magnifyingglass").foregroundColor(.secondary) }
                    )
                }
            }

            Section(header: Text("Routing")) {
                Toggle(isOn: $excludeLocalNetworks) {
                    VStack(alignment: .leading) {
                        Text("Allow LAN Access")
                        Text("Access local network devices without routing through VPN")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Toggle(isOn: $excludeAPNs) {
                    VStack(alignment: .leading) {
                        Text("Bypass APNs")
                        Text("Send push notifications directly, bypassing the tunnel")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Toggle(isOn: $excludeCellularServices) {
                    VStack(alignment: .leading) {
                        Text("Bypass Cellular")
                        Text("Exclude calls, SMS, and voicemail from the tunnel")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section(header: Text("Extended Features")) {
                NavigationLink(destination: SplitTunnelSettingsView()) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Split-Tunneling")
                        Text(SplitTunnelStorage.ruleCountSummary())
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                NavigationLink(
                    destination: TrustedWiFiSettingsView { settings in
                        trustedWiFiSummary = TrustedWiFiStorage.summary(settings)
                        TunnelOnDemandController.refreshTrustedWiFiPreferences()
                    }
                ) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Trusted Wi-Fi")
                        Text(trustedWiFiSummary)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Button {
                    showVKAuthorization = true
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("VK Authorization")
                        Text(vkAuthorizationStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            if SharedLogger.isDegradedResignedBuild {
                Section {
                    Text("This build is running without the shared App Group container. Split-tunnel rules are stored locally in the app, but widgets, live activities, and shortcut control actions may be unavailable.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section(header: Text("Captcha")) {
                Toggle(isOn: $manualCaptcha) {
                    VStack(alignment: .leading) {
                        Text("Manual Captcha")
                        Text("Disable automatic captcha solving and require manual solving flow")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Toggle(isOn: $showCaptchaFallbackURL) {
                    VStack(alignment: .leading) {
                        Text("View Captcha fallback URL")
                        Text("Show the raw fallback URL and direct link in the captcha screen.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section(header: Text("Updates")) {
                Toggle(isOn: $autoUpdateEnabled) {
                    VStack(alignment: .leading) {
                        Text("Autoupdate")
                        Text("Check GitHub Releases and offer download when a newer version is available")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section(header: Text("Experimental")) {
                Toggle(isOn: $tetherProxyEnabled) {
                    VStack(alignment: .leading) {
                        Text("Tether proxy")
                        Text("Bind proxy on all interfaces so clients in the same LAN can connect")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if tetherProxyEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        if let address = LocalNetworkAddressResolver.currentIPv4Address() {
                            Text("Connect from LAN:")
                                .font(.subheadline.weight(.semibold))
                            Text("\(address):\(tetherProxyPort)")
                                .font(.caption.monospaced())
                                .foregroundColor(.secondary)
                            Text("Use this as HTTP/SOCKS proxy endpoint on another device in the same Wi-Fi.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Connect from LAN:")
                                .font(.subheadline.weight(.semibold))
                            Text("IP not detected. Connect iPhone to Wi-Fi and reopen this screen.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section(header: Text("Appearance")) {
                Picker("Theme", selection: $appTheme) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showVKAuthorization) {
            VKAuthorizationView(
                onSuccess: {
                    vkAuthorizationStatus = "VK session saved"
                },
                onCancel: {}
            )
        }
        .onAppear {
            trustedWiFiSummary = TrustedWiFiStorage.summary(TrustedWiFiStorage.load())
            vkAuthorizationStatus = VKAuthSessionStore.loadAccessToken() == nil ? "No saved VK sessions" : "VK session saved"
        }
    }
}

private enum LocalNetworkAddressResolver {
    static func currentIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr = firstAddr
        while true {
            let interface = ptr.pointee
            guard let sockaddrPointer = interface.ifa_addr else {
                guard let next = interface.ifa_next else { break }
                ptr = next
                continue
            }

            let family = sockaddrPointer.pointee.sa_family
            if family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(
                        sockaddrPointer,
                        socklen_t(sockaddrPointer.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                    let address = String(cString: hostname)
                    if !address.isEmpty { return address }
                }
            }
            guard let next = interface.ifa_next else { break }
            ptr = next
        }
        return nil
    }
}
