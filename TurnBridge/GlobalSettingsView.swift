import SwiftUI
import Foundation
import Darwin
import Network
import UniformTypeIdentifiers

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
    static let createListURL = "https://iplist.opencck.org/"

    static func load() -> SplitTunnelSettings {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: enabledKey) as? Bool ?? false
        let mode = SplitTunnelMode(rawValue: defaults.string(forKey: modeKey) ?? "") ?? .direct
        let rules = defaults.stringArray(forKey: rulesKey) ?? []
        return SplitTunnelSettings(enabled: enabled, mode: mode, rules: deduplicatedRules(rules))
    }

    static func save(_ settings: SplitTunnelSettings) {
        let defaults = UserDefaults.standard
        defaults.set(settings.enabled, forKey: enabledKey)
        defaults.set(settings.mode.rawValue, forKey: modeKey)
        defaults.set(deduplicatedRules(settings.rules), forKey: rulesKey)
    }

    static func ruleCountSummary(_ settings: SplitTunnelSettings) -> String {
        let count = settings.rules.count
        return count == 1 ? "1 rule" : "\(count) rules"
    }

    static func exportedText(from settings: SplitTunnelSettings) -> String {
        deduplicatedRules(settings.rules).joined(separator: "\n")
    }

    static func exportURL(for settings: SplitTunnelSettings) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vbridge-split-data.txt")
        let text = exportedText(from: settings)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func merge(_ incomingRules: [String], into settings: inout SplitTunnelSettings) {
        settings.rules = deduplicatedRules(settings.rules + incomingRules)
        save(settings)
    }

    static func removeRule(at offsets: IndexSet, from settings: inout SplitTunnelSettings) {
        settings.rules.remove(atOffsets: offsets)
        save(settings)
    }

    static func clearRules(from settings: inout SplitTunnelSettings) {
        settings.rules.removeAll()
        save(settings)
    }

    static func addRule(_ rawValue: String, to settings: inout SplitTunnelSettings) throws {
        guard let normalized = normalizedRule(rawValue) else {
            throw SplitTunnelValidationError.invalidRule
        }
        merge([normalized], into: &settings)
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
        let lines = text.replacingOccurrences(of: "\r", with: "\n").components(separatedBy: .newlines)
        let normalized = lines.compactMap(normalizedRule)
        guard !normalized.isEmpty else {
            throw SplitTunnelValidationError.noValidRules
        }
        return deduplicatedRules(normalized)
    }

    static func normalizedRule(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.hasPrefix("#"), !trimmed.hasPrefix("//"), !trimmed.hasPrefix(";") else { return nil }

        if let normalizedIP = normalizedIPAddressRule(trimmed) {
            return normalizedIP
        }

        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("*.") {
            let suffix = String(lowered.dropFirst(2))
            return isValidDomain(suffix) ? "*.\(suffix)" : nil
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
            return "Invalid rule. Supported formats: `*.domain`, `example.com`, `IP`, `IP/MASK`."
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

    let showsDoneButton: Bool

    @State private var settings = SplitTunnelStorage.load()
    @State private var errorMessage = ""
    @State private var showErrorAlert = false

    init(showsDoneButton: Bool = false) {
        self.showsDoneButton = showsDoneButton
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
                    Text("IP and CIDR rules are applied directly. Domain rules are resolved to IPs when the tunnel starts.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 2)

                NavigationLink(destination: SplitTunnelRuleListView(settings: $settings)) {
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
            }

            Section(header: Text("Formats")) {
                Text("Supported masks: `*.domain`, exact domains, `IP`, `IP/MASK`.")
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
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { settings.enabled },
            set: { newValue in
                settings.enabled = newValue
                SplitTunnelStorage.save(settings)
            }
        )
    }

    private var modeBinding: Binding<SplitTunnelMode> {
        Binding(
            get: { settings.mode },
            set: { newValue in
                settings.mode = newValue
                SplitTunnelStorage.save(settings)
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
}

private struct SplitTunnelRuleListView: View {
    @Binding var settings: SplitTunnelSettings

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
                        Text("Add domains, wildcard domains, IPs, or CIDR ranges. Imported lists are merged into the same app-wide list.")
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

                ShareLink(item: SplitTunnelStorage.exportURL(for: settings)) {
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
                    try SplitTunnelStorage.addRule(newRuleText, to: &settings)
                } catch {
                    show(error)
                }
            }
        } message: {
            Text("Supported formats: `*.domain`, exact domains, `IP`, `IP/MASK`.")
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
                SplitTunnelStorage.clearRules(from: &settings)
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
            SplitTunnelStorage.merge(rules, into: &settings)
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
                    SplitTunnelStorage.merge(rules, into: &settings)
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
        SplitTunnelStorage.removeRule(at: offsets, from: &settings)
    }

    private func show(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        showErrorAlert = true
    }

    private func isIPAddressRule(_ rule: String) -> Bool {
        rule.contains("/") || IPv4Address(rule) != nil || IPv6Address(rule) != nil
    }

    private func ruleDescription(_ rule: String) -> String {
        if rule.hasPrefix("*.") {
            return "Wildcard domain suffix"
        }
        if IPv4Address(rule) != nil || IPv6Address(rule) != nil {
            return "Single IP address"
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
                        Text(SplitTunnelStorage.ruleCountSummary(SplitTunnelStorage.load()))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
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
