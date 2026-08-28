import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UIKit
import WireGuardKitGo

private enum DeployAction: String, Sendable {
    case install
    case updatePreserve = "update_preserve"
    case reinstall
    case uninstall
    case status
    case liveLog = "live_log"
    case exportLogs = "export_logs"
    case cleanupDevices = "cleanup_devices"
    case exportState = "export_state"
    case importState = "import_state"
}

private struct DeployRequest: Encodable, Sendable {
    var deployKind: String
    var action: String
    var host: String
    var user: String
    var password: String
    var port: Int
    var deployScriptPath: String
    var serverBinaryPath: String
    var mainPassword: String
    var csqttTunnelPassword: String
    var csqttWebUser: String
    var csqttWebPassword: String
    var adminId: String
    var botToken: String
    var dtlsPort: Int
    var wgPort: Int
    var dns1: String
    var dns2: String
    var maxPasswords: Int
    var maxWorkersPerAccess: Int
    var maxHandshakes: Int
    var handshakeRate: Int
    var maxClientMbps: Int
    var wdttExistingTunEnabled: Bool
    var wdttExistingTunName: String
    var stateArchiveBase64: String
}

private struct DeployResponse: Decodable, Sendable {
    var ok: Bool
    var status: String
    var message: String
    var output: String
    var serverConnected: Bool?
    var wdttInstalled: Bool?
    var readyToConnect: Bool?
    var serverVersion: String?
    var dtlsPort: Int?
    var wgPort: Int?
    var dns1: String?
    var dns2: String?
    var mainPassword: String?
    var csqttTunnelPassword: String?
    var csqttWebUser: String?
    var csqttWebPassword: String?
    var adminId: String?
    var botToken: String?
}

private enum WDTTInstallFlavor {
    case stable
    case plus

    var buttonTitle: String {
        switch self {
        case .stable:
            return "Install WDTT"
        case .plus:
            return "Install WDTT Plus"
        }
    }

    var progressTitle: String {
        switch self {
        case .stable:
            return "Installing WDTT..."
        case .plus:
            return "Installing WDTT Plus..."
        }
    }

    var scriptName: String {
        switch self {
        case .stable:
            return "wdtt"
        case .plus:
            return "wdtt-plus"
        }
    }

    var binaryPrefix: String {
        switch self {
        case .stable:
            return "wdtt"
        case .plus:
            return "wdtt-plus"
        }
    }
}

struct DeployView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @AppStorage("deploy.kind") private var deployKind = DeployServerKind.wdttPlus.rawValue
    @AppStorage("deploy.launchAction") private var launchActionRaw = ""
    @AppStorage("deploy.host") private var host = ""
    @AppStorage("deploy.user") private var user = "root"
    @AppStorage("deploy.password") private var password = ""
    @AppStorage("deploy.sshPort") private var sshPort = 22
    @AppStorage("deploy.dns1") private var dns1 = "1.1.1.1"
    @AppStorage("deploy.dns2") private var dns2 = "1.0.0.1"
    @AppStorage("deploy.mainPassword") private var mainPassword = ""
    @AppStorage("deploy.csqttTunnelPassword") private var csqttTunnelPassword = ""
    @AppStorage("deploy.csqttWebUser") private var csqttWebUser = "admin"
    @AppStorage("deploy.csqttWebPassword") private var csqttWebPassword = ""
    @AppStorage("deploy.adminId") private var adminId = ""
    @AppStorage("deploy.botToken") private var botToken = ""
    @AppStorage("deploy.manualPorts") private var manualPorts = false
    @AppStorage("deploy.dtlsPort") private var dtlsPort = 56000
    @AppStorage("deploy.wgPort") private var wgPort = 56001
    @AppStorage("deploy.wdttManualPorts") private var wdttManualPorts = false
    @AppStorage("deploy.wdttDtlsPort") private var wdttDtlsPort = 56000
    @AppStorage("deploy.wdttWgPort") private var wdttWgPort = 56001
    @AppStorage("deploy.csqttManualPorts") private var csqttManualPorts = false
    @AppStorage("deploy.csqttPeerPort") private var csqttPeerPort = 46000
    @AppStorage("deploy.csqttWebPort") private var csqttWebPort = 46002
    @AppStorage("deploy.serverArch") private var serverArch = "amd64"
    @AppStorage("deploy.maxPasswords") private var maxPasswords = 50
    @AppStorage("deploy.maxWorkersPerAccess") private var maxWorkersPerAccess = 0
    @AppStorage("deploy.maxHandshakes") private var maxHandshakes = 32
    @AppStorage("deploy.handshakeRate") private var handshakeRate = 24
    @AppStorage("deploy.maxClientMbps") private var maxClientMbps = 0
    @AppStorage("deploy.wdttExistingTunEnabled") private var wdttExistingTunEnabled = false
    @AppStorage("deploy.wdttExistingTunName") private var wdttExistingTunName = ""

    @State private var isRunning = false
    @State private var currentAction: DeployAction?
    @State private var resultTitle = ""
    @State private var resultMessage = ""
    @State private var output = ""
    @State private var showAlert = false
    @State private var showCleanupConfirmation = false
    @State private var showExportConfirmation = false
    @State private var showReinstallConfirmation = false
    @State private var showImportStatePicker = false
    @State private var exportedLogsURL: URL?
    @State private var shareLogsURL: URL?
    @State private var shareStateURL: URL?
    @State private var isCheckingServerStatus = false
    @State private var didConsumeLaunchAction = false
    @State private var lastLoadedDeployKind: DeployServerKind?
    @State private var liveOutputTask: Task<Void, Never>?
    @State private var serverConnected: Bool?
    @State private var wdttInstalled: Bool?
    @State private var readyToConnect: Bool?
    @State private var currentInstallFlavor: WDTTInstallFlavor?
    private let wdttServerArchitectures = ["amd64", "arm64"]
    private let maxPasswordsOptions = [10, 25, 50, 75, 100, 150, 200, 300, 500]
    private let maxWorkersPerAccessOptions = [0, 9, 18, 27, 36, 45, 54, 72, 90, 108]
    private let maxHandshakesOptions = [8, 16, 24, 32, 48, 64, 96, 128]
    private let handshakeRateOptions = [6, 12, 18, 24, 32, 48, 64]
    private let maxClientMbpsOptions = [0, 1, 2, 5, 10, 20, 50, 100, 200]

    var body: some View {
        Form {
            Section(header: Text("What to Deploy")) {
                Picker("Server Type", selection: $deployKind) {
                    ForEach(DeployServerKind.allCases) { kind in
                        Text(kind.title).tag(kind.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section(header: Text("Server")) {
                TextField("IP server or domain", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                TextField("Login", text: $user)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                secretField("SSH Password", text: $password)

                TextField("SSH Port", value: $sshPort, format: .number)
                    .keyboardType(.numberPad)

                if !isSSHPortValid {
                    Text("SSH port must be between 1 and 65535")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            if hasSavedServerSettings {
                Section(header: Text("Server Status")) {
                    DeployStatusRow(title: "Server connected", value: serverConnected, isChecking: isCheckingServerStatus)
                    DeployStatusRow(title: installedStatusTitle, value: wdttInstalled, isChecking: isCheckingServerStatus)
                    DeployStatusRow(title: "Ready to connect", value: readyToConnect, isChecking: isCheckingServerStatus)
                }
            }

            if isWDTTFamily {
                Section(header: Text("DNS")) {
                    TextField("Primary DNS", text: $dns1)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)

                    TextField("Secondary DNS", text: $dns2)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                }
            }

            if isWDTTFamily {
                Section(header: Text("Secrets")) {
                    secretField("WDTT Main Password", text: $mainPassword)

                    if !mainPassword.isEmpty && !isSecretValueValid(mainPassword) {
                        Text("Allowed: letters, digits, and _ . ! ? : # - /")
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    copyableTextField("Telegram Admin ID", text: $adminId, keyboardType: .numberPad)
                    secretField("Telegram Bot Token", text: $botToken)
                }
            } else {
                Section(header: Text("Secrets")) {
                    secretField("CSQTT Tunnel Password", text: $csqttTunnelPassword)
                    secretField("CSQTT Web Password", text: $csqttWebPassword)

                    if !csqttTunnelPassword.isEmpty && !isSecretValueValid(csqttTunnelPassword) {
                        Text("Allowed: letters, digits, and _ . ! ? : # - /")
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    if !csqttWebPassword.isEmpty && !isSecretValueValid(csqttWebPassword) {
                        Text("Allowed: letters, digits, and _ . ! ? : # - /")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                Section(header: Text("Web Panel")) {
                    copyableTextField("CSQTT Web Login", text: $csqttWebUser)

                    Button {
                        openCSQTTWebPanel()
                    } label: {
                        Label("Open Web Panel", systemImage: "safari")
                    }
                    .disabled(csqttWebPanelURL == nil)

                    Button {
                        copyCSQTTWebPanelLink()
                    } label: {
                        Label("Copy Web Panel Link", systemImage: "link")
                    }
                    .disabled(csqttWebPanelURL == nil)
                }
            }

            Section(header: Text("Ports")) {
                Toggle("Manual port control", isOn: $manualPorts)

                if manualPorts {
                    TextField(primaryPortTitle, value: $dtlsPort, format: .number)
                        .keyboardType(.numberPad)
                    TextField(secondaryPortTitle, value: $wgPort, format: .number)
                        .keyboardType(.numberPad)

                    if !isValidPort(dtlsPort) {
                        Text("\(primaryPortTitle) must be between 1 and 65535")
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    if !isValidPort(wgPort) {
                        Text("\(secondaryPortTitle) must be between 1 and 65535")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }

            Section(header: Text("Server Binary")) {
                Picker("Architecture", selection: $serverArch) {
                    ForEach(serverArchitectures, id: \.self) { arch in
                        Text(arch).tag(arch)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                if supportsWDTTPlusManagement || selectedDeployKind == .csqtt {
                    NavigationLink {
                        ServerManagementView(
                            target: serverManagementTarget,
                            canConnect: canConnect
                        )
                    } label: {
                        Label("Management", systemImage: "person.3")
                    }
                    .disabled(serverManagementTarget == nil)
                }

                if supportsOutboundManagement {
                    NavigationLink {
                        OutboundManagementView(
                            target: serverOutboundTarget,
                            canConnect: canConnect
                        )
                    } label: {
                        Label("Outbound IP / Proxy", systemImage: "network")
                    }

                    Button {
                        showExportConfirmation = true
                    } label: {
                        Label("Export Server", systemImage: "link.badge.plus")
                    }
                    .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !isSSHPortValid)
                }

                Button {
                    run(.exportLogs)
                } label: {
                    Label(isRunning && currentAction == .exportLogs ? "Exporting Logs..." : "Export Logs", systemImage: "square.and.arrow.up")
                }
                .disabled(!canConnect)

                if supportsBackupRestore {
                    Button {
                        run(.exportState)
                    } label: {
                        Label(isRunning && currentAction == .exportState ? "Creating Backup..." : "Backup Server", systemImage: "externaldrive.badge.icloud")
                    }
                    .disabled(!canUseStateArchive)

                    Button {
                        showImportStatePicker = true
                    } label: {
                        Label(isRunning && currentAction == .importState ? "Restoring Backup..." : "Restore Server", systemImage: "arrow.clockwise.icloud")
                    }
                    .disabled(!canUseStateArchive)
                }

                if isWDTTStable {
                    Button {
                        runInstall(.stable)
                    } label: {
                        Label(
                            isRunning && currentAction == .install && currentInstallFlavor == .stable
                                ? WDTTInstallFlavor.stable.progressTitle
                                : WDTTInstallFlavor.stable.buttonTitle,
                            systemImage: "arrow.down.circle"
                        )
                    }
                    .disabled(!canInstall)

                }

                if isWDTTPlus {
                    Button {
                        runInstall(.plus)
                    } label: {
                        Label(
                            isRunning && currentAction == .install && currentInstallFlavor == .plus
                                ? WDTTInstallFlavor.plus.progressTitle
                                : WDTTInstallFlavor.plus.buttonTitle,
                            systemImage: "icloud.and.arrow.up"
                        )
                    }
                    .disabled(!canInstall)
                } else if selectedDeployKind == .csqtt {
                    Button {
                        run(.install)
                    } label: {
                        Label(isRunning && currentAction == .install ? "Installing..." : "Install", systemImage: "icloud.and.arrow.up")
                    }
                    .disabled(!canInstall)
                }

                if supportsUpdatePreserve {
                    Button {
                        run(.updatePreserve)
                    } label: {
                        Label(isRunning && currentAction == .updatePreserve ? "Updating..." : "Update With Preserve", systemImage: "arrow.clockwise.circle")
                    }
                    .disabled(!canUpdatePreserve)
                }

                Button {
                    run(.status)
                } label: {
                    Label(isRunning && currentAction == .status ? "Checking..." : "Status", systemImage: "waveform.path.ecg")
                }
                .disabled(!canConnect)

                if supportsCleanupDevices {
                    Button(role: .destructive) {
                        showCleanupConfirmation = true
                    } label: {
                        Label(isRunning && currentAction == .cleanupDevices ? "Cleaning..." : "Clean Orphan Devices", systemImage: "externaldrive.badge.xmark")
                    }
                    .disabled(!canCleanupDevices)
                }

                if supportsReinstall {
                    Button(role: .destructive) {
                        showReinstallConfirmation = true
                    } label: {
                        Label(isRunning && currentAction == .reinstall ? "Reinstalling..." : "Reinstall", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(!canInstall)
                }

                Button(role: .destructive) {
                    run(.uninstall)
                } label: {
                    Label(isRunning && currentAction == .uninstall ? "Removing..." : "Uninstall", systemImage: "trash")
                }
                .disabled(!canConnect)
            }

            if isWDTTPlus {
                Section(header: Text("Advanced Server")) {
                    Toggle("Use Existing TUN Interface", isOn: $wdttExistingTunEnabled)

                    if wdttExistingTunEnabled {
                        TextField("Existing TUN Interface", text: $wdttExistingTunName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        Text("Passes `-existing-tun <iface>` to WDTT deploy arguments so the server can try to route through an already running TUN interface on the VPS.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Picker("Max Passwords", selection: $maxPasswords) {
                        ForEach(maxPasswordsOptions, id: \.self) { value in
                            Text("\(value)").tag(value)
                        }
                    }

                    Picker("Max Workers Per Access", selection: $maxWorkersPerAccess) {
                        ForEach(maxWorkersPerAccessOptions, id: \.self) { value in
                            Text(value == 0 ? "Unlimited" : "\(value)").tag(value)
                        }
                    }

                    Picker("Max Handshakes", selection: $maxHandshakes) {
                        ForEach(maxHandshakesOptions, id: \.self) { value in
                            Text("\(value)").tag(value)
                        }
                    }

                    Picker("Handshake Rate", selection: $handshakeRate) {
                        ForEach(handshakeRateOptions, id: \.self) { value in
                            Text("\(value)").tag(value)
                        }
                    }

                    Picker("Max Client Mbps", selection: $maxClientMbps) {
                        ForEach(maxClientMbpsOptions, id: \.self) { value in
                            Text(value == 0 ? "Unlimited" : "\(value) Mbps").tag(value)
                        }
                    }
                }
            }

            if isRunning && output.isEmpty {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }

            if !output.isEmpty {
                Section(header: Text("Output")) {
                    ScrollView(.vertical) {
                        Text(output)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 140)
                }
            }
        }
        .navigationTitle("Deploy")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") {
                    dismiss()
                }
            }
        }
        .alert(resultTitle, isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(resultMessage)
        }
        .confirmationDialog(
            "Clean orphan WDTT devices?",
            isPresented: $showCleanupConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clean Orphan Devices", role: .destructive) {
                run(.cleanupDevices)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The server database will be backed up. Devices bound to individual passwords are preserved; only unbound device records are removed.")
        }
        .confirmationDialog(
            "Export server settings?",
            isPresented: $showExportConfirmation,
            titleVisibility: .visible
        ) {
            Button("Copy Link") {
                exportServerSettings()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The link contains the SSH password, WDTT password, and Telegram credentials. Share it only through a trusted private channel.")
        }
        .confirmationDialog(
            "Reinstall \(selectedDeployKind.title) on the server?",
            isPresented: $showReinstallConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reinstall", role: .destructive) {
                run(.reinstall)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The app will uninstall \(selectedDeployKind.title) from the server and then install it again using the current Deploy settings.")
        }
        .task {
            syncVisiblePorts(for: selectedDeployKind)
            await refreshSavedServerStatus()
            consumePendingLaunchActionIfNeeded()
        }
        .onChange(of: deployKind) { newValue in
            guard let kind = DeployServerKind(rawValue: newValue) else { return }
            if let previousKind = lastLoadedDeployKind {
                persistVisiblePorts(for: previousKind)
            }
            syncVisiblePorts(for: kind)
            if kind == .csqtt {
                if serverArch != "amd64" {
                    serverArch = "amd64"
                }
            }

            clearStatusIndicators()
            Task {
                await refreshSavedServerStatus()
                consumePendingLaunchActionIfNeeded()
            }
        }
        .onChange(of: manualPorts) { _ in
            persistVisiblePorts(for: selectedDeployKind)
        }
        .onChange(of: dtlsPort) { _ in
            persistVisiblePorts(for: selectedDeployKind)
        }
        .onChange(of: wgPort) { _ in
            persistVisiblePorts(for: selectedDeployKind)
        }
        .sheet(isPresented: Binding(
            get: { shareLogsURL != nil },
            set: { isPresented in
                if !isPresented {
                    shareLogsURL = nil
                }
            }
        )) {
            if let url = shareLogsURL {
                ActivityView(items: [url])
            }
        }
        .sheet(isPresented: Binding(
            get: { shareStateURL != nil },
            set: { isPresented in
                if !isPresented {
                    shareStateURL = nil
                }
            }
        )) {
            if let url = shareStateURL {
                ActivityView(items: [url])
            }
        }
        .sheet(isPresented: $showImportStatePicker) {
            DocumentPicker(
                contentTypes: [.json, .plainText, .text],
                onPick: { url in
                    showImportStatePicker = false
                    importServerState(from: url)
                },
                onCancel: {
                    showImportStatePicker = false
                }
            )
        }
    }

    private var effectiveDTLSPort: Int {
        manualPorts ? dtlsPort : defaultPrimaryPort
    }

    private var effectiveWGPort: Int {
        manualPorts ? wgPort : defaultSecondaryPort
    }

    private var selectedDeployKind: DeployServerKind {
        DeployServerKind(rawValue: deployKind) ?? .wdttPlus
    }

    private var isWDTTStable: Bool {
        selectedDeployKind == .wdtt
    }

    private var isWDTTPlus: Bool {
        selectedDeployKind == .wdttPlus
    }

    private var isWDTTFamily: Bool {
        isWDTTStable || isWDTTPlus
    }

    private var supportsWDTTPlusManagement: Bool {
        isWDTTPlus
    }

    private var supportsBackupRestore: Bool {
        isWDTTPlus
    }

    private var supportsCleanupDevices: Bool {
        isWDTTPlus
    }

    private var supportsUpdatePreserve: Bool {
        isWDTTPlus
    }

    private var supportsReinstall: Bool {
        isWDTTPlus || selectedDeployKind == .csqtt
    }

    private var supportsOutboundManagement: Bool {
        isWDTTPlus
    }

    private var supportsExportServer: Bool {
        isWDTTPlus
    }

    private var serverArchitectures: [String] {
        isWDTTFamily ? wdttServerArchitectures : ["amd64"]
    }

    private var defaultPrimaryPort: Int {
        isWDTTFamily ? 56000 : 46000
    }

    private var defaultSecondaryPort: Int {
        isWDTTFamily ? 56001 : 46002
    }

    private var primaryPortTitle: String {
        isWDTTFamily ? "DTLS Port" : "Peer Port"
    }

    private var secondaryPortTitle: String {
        isWDTTFamily ? "WireGuard Port" : "Web Port"
    }

    private var installedStatusTitle: String {
        isWDTTFamily ? "\(selectedDeployKind.title) installed" : "CSQTT installed"
    }

    private var canConnect: Bool {
        !isRunning && !isCheckingServerStatus && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty && isSSHPortValid
    }

    private var hasSavedServerSettings: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    private var canInstall: Bool {
        canConnect &&
        isValidPort(effectiveDTLSPort) &&
        isValidPort(effectiveWGPort) &&
        (isWDTTFamily
            ? isSecretValueValid(mainPassword)
            : isSecretValueValid(csqttTunnelPassword) && isSecretValueValid(csqttWebPassword))
    }

    private var canUpdatePreserve: Bool {
        supportsUpdatePreserve && canInstall
    }

    private var canUseStateArchive: Bool {
        supportsBackupRestore && canConnect
    }

    private var canCleanupDevices: Bool {
        supportsCleanupDevices && canConnect
    }

    private func isSecretValueValid(_ value: String) -> Bool {
        let pattern = #"^[a-zA-Z0-9_.!?:#/-]+$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private var isSSHPortValid: Bool {
        (1...65535).contains(sshPort)
    }

    private func run(_ action: DeployAction) {
        guard !isRunning else { return }
        currentInstallFlavor = nil
        if action == .reinstall {
            runReinstall()
            return
        }

        let request: DeployRequest
        do {
            request = try makeRequest(action)
        } catch {
            resultTitle = "Deploy Failed"
            resultMessage = error.localizedDescription
            showAlert = true
            return
        }

        isRunning = true
        currentAction = action
        output = ""
        startLiveOutputPolling(for: request)

        Task {
            let response = await perform(request)
            await MainActor.run {
                stopLiveOutputPolling()
                isRunning = false
                currentAction = nil
                output = response.output
                updateStatusIndicators(response)
                if action == .status {
                    applyDiscoveredServerSettings(response)
                }
                if action == .exportLogs, response.ok,
                   let url = writeExportedLogsFile(contents: response.output) {
                    exportedLogsURL = url
                    shareLogsURL = url
                }
                if action == .exportState, response.ok,
                   let url = writeExportedStateFile(contents: response.output) {
                    shareStateURL = url
                }
                resultTitle = response.ok ? "Deploy Complete" : "Deploy Failed"
                resultMessage = response.message
                showAlert = true

                if response.ok {
                    SharedLogger.info("\(selectedDeployKind.title) deploy \(action.rawValue) completed")
                } else {
                    SharedLogger.error("\(selectedDeployKind.title) deploy \(action.rawValue) failed: \(response.message)")
                }
                if !response.output.isEmpty {
                    SharedLogger.info("\(selectedDeployKind.title) deploy output:\n\(response.output)")
                }
            }
        }
    }

    private func runInstall(_ flavor: WDTTInstallFlavor) {
        guard !isRunning else { return }

        let request: DeployRequest
        do {
            request = try makeRequest(.install, wdttInstallFlavor: flavor)
        } catch {
            resultTitle = "Deploy Failed"
            resultMessage = error.localizedDescription
            showAlert = true
            return
        }

        isRunning = true
        currentAction = .install
        currentInstallFlavor = flavor
        output = ""
        startLiveOutputPolling(for: request)

        Task {
            let response = await perform(request)
            await MainActor.run {
                stopLiveOutputPolling()
                isRunning = false
                currentAction = nil
                currentInstallFlavor = nil
                output = response.output
                updateStatusIndicators(response)
                resultTitle = response.ok ? "Deploy Complete" : "Deploy Failed"
                resultMessage = response.message
                showAlert = true

                let flavorLabel = flavor == .stable ? "WDTT" : "WDTT Plus"
                if response.ok {
                    SharedLogger.info("\(flavorLabel) deploy install completed")
                } else {
                    SharedLogger.error("\(flavorLabel) deploy install failed: \(response.message)")
                }
                if !response.output.isEmpty {
                    SharedLogger.info("\(flavorLabel) deploy output:\n\(response.output)")
                }
            }
        }
    }

    private func runReinstall() {
        let uninstallRequest: DeployRequest
        let installRequest: DeployRequest
        do {
            uninstallRequest = try makeRequest(.uninstall)
            installRequest = try makeRequest(.install)
        } catch {
            resultTitle = "Reinstall Failed"
            resultMessage = error.localizedDescription
            showAlert = true
            return
        }

        isRunning = true
        currentAction = .reinstall
        output = ""
        startLiveOutputPolling(for: uninstallRequest)

        Task {
            let uninstallResponse = await perform(uninstallRequest)
            var combinedOutput = "== reinstall: uninstall ==\n"
            if uninstallResponse.output.isEmpty {
                combinedOutput += uninstallResponse.message
            } else {
                combinedOutput += uninstallResponse.output
            }
            if !combinedOutput.hasSuffix("\n") {
                combinedOutput += "\n"
            }

            guard uninstallResponse.ok else {
                await MainActor.run {
                    stopLiveOutputPolling()
                    isRunning = false
                    currentAction = nil
                    output = combinedOutput
                    updateStatusIndicators(uninstallResponse)
                    resultTitle = "Reinstall Failed"
                    resultMessage = "Uninstall step failed: \(uninstallResponse.message)"
                    showAlert = true
                    SharedLogger.error("\(selectedDeployKind.title) reinstall failed during uninstall: \(uninstallResponse.message)")
                    if !combinedOutput.isEmpty {
                        SharedLogger.info("\(selectedDeployKind.title) reinstall output:\n\(combinedOutput)")
                    }
                }
                return
            }

            await MainActor.run {
                stopLiveOutputPolling()
                output = combinedOutput
                startLiveOutputPolling(for: installRequest)
            }

            let installResponse = await perform(installRequest)
            combinedOutput += "== reinstall: install ==\n"
            if installResponse.output.isEmpty {
                combinedOutput += installResponse.message
            } else {
                combinedOutput += installResponse.output
            }

            await MainActor.run {
                stopLiveOutputPolling()
                isRunning = false
                currentAction = nil
                output = combinedOutput
                updateStatusIndicators(installResponse)
                if installResponse.ok {
                    applyDiscoveredServerSettings(installResponse)
                    resultTitle = "Reinstall Complete"
                    resultMessage = "\(selectedDeployKind.title) was reinstalled with the current Deploy settings."
                    SharedLogger.info("\(selectedDeployKind.title) reinstall completed")
                } else {
                    resultTitle = "Reinstall Failed"
                    resultMessage = "Install step failed: \(installResponse.message)"
                    SharedLogger.error("\(selectedDeployKind.title) reinstall failed during install: \(installResponse.message)")
                }
                showAlert = true
                if !combinedOutput.isEmpty {
                    SharedLogger.info("\(selectedDeployKind.title) reinstall output:\n\(combinedOutput)")
                }
            }
        }
    }

    private func exportServerSettings() {
        let settings = DeploySettingsLink(
            version: 1,
            nonce: UUID(),
            deployKind: selectedDeployKind,
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            user: user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "root" : user.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password,
            sshPort: sshPort,
            dns1: dns1,
            dns2: dns2,
            mainPassword: mainPassword,
            csqttTunnelPassword: csqttTunnelPassword,
            csqttWebUser: csqttWebUser,
            csqttWebPassword: csqttWebPassword,
            adminId: adminId,
            botToken: botToken,
            manualPorts: manualPorts,
            dtlsPort: dtlsPort,
            wgPort: wgPort,
            serverArch: serverArch,
            wdttExistingTunEnabled: wdttExistingTunEnabled,
            wdttExistingTunName: wdttExistingTunName
        )
        do {
            UIPasteboard.general.string = try ConfigParser.exportDeploySettings(settings)
            resultTitle = "Server Exported"
            resultMessage = "The private server settings link was copied to the clipboard."
        } catch {
            resultTitle = "Export Failed"
            resultMessage = error.localizedDescription
        }
        showAlert = true
    }

    @MainActor
    private func refreshSavedServerStatus() async {
        guard !isRunning, hasSavedServerSettings, isSSHPortValid else {
            clearStatusIndicators()
            return
        }

        let request: DeployRequest
        do {
            request = try makeRequest(.status)
        } catch {
            clearStatusIndicators()
            return
        }

        isCheckingServerStatus = true
        let response = await perform(request)
        isCheckingServerStatus = false
        updateStatusIndicators(response)
    }

    private func perform(_ request: DeployRequest) async -> DeployResponse {
        await Task.detached(priority: .userInitiated) {
            do {
                let data = try JSONEncoder().encode(request)
                guard let json = String(data: data, encoding: .utf8) else {
                    throw DeployError.invalidJSON
                }

                let pointer = json.withCString {
                    VBridgeWGDeployServer(UnsafeMutablePointer(mutating: $0))
                }
                guard let pointer else {
                    throw DeployError.emptyResponse
                }
                defer { VBridgeWGFreeCString(pointer) }

                let responseJSON = String(cString: pointer)
                guard let responseData = responseJSON.data(using: .utf8) else {
                    throw DeployError.invalidResponse(responseJSON)
                }
                return try JSONDecoder().decode(DeployResponse.self, from: responseData)
            } catch {
                return DeployResponse(ok: false, status: "error", message: error.localizedDescription, output: "")
            }
        }.value
    }

    @MainActor
    private func startLiveOutputPolling(for request: DeployRequest) {
        stopLiveOutputPolling()
        guard request.action == DeployAction.install.rawValue ||
              request.action == DeployAction.updatePreserve.rawValue ||
              request.action == DeployAction.uninstall.rawValue else {
            return
        }

        liveOutputTask = Task {
            while !Task.isCancelled {
                var liveRequest = request
                liveRequest.action = DeployAction.liveLog.rawValue
                let response = await perform(liveRequest)
                if Task.isCancelled {
                    return
                }
                if !response.output.isEmpty {
                    await MainActor.run {
                        output = response.output
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    @MainActor
    private func stopLiveOutputPolling() {
        liveOutputTask?.cancel()
        liveOutputTask = nil
    }

    private func makeRequest(_ action: DeployAction, wdttInstallFlavor: WDTTInstallFlavor? = nil) throws -> DeployRequest {
        let scriptName: String = {
            guard isWDTTFamily else { return "csqtt-deploy" }
            if action == .install, let wdttInstallFlavor {
                return wdttInstallFlavor.scriptName
            }
            return isWDTTPlus ? "wdtt-plus" : "wdtt"
        }()
        let scriptURL = Bundle.main.url(forResource: scriptName, withExtension: "sh")
        if (action == .install || action == .updatePreserve || action == .uninstall), scriptURL == nil {
            throw DeployError.missingAsset("\(scriptName).sh")
        }

        let binaryPrefix: String = {
            guard isWDTTFamily else { return "csqtt" }
            if action == .install, let wdttInstallFlavor {
                return wdttInstallFlavor.binaryPrefix
            }
            return isWDTTPlus ? "wdtt-plus" : "wdtt"
        }()
        let binaryName = "\(binaryPrefix)-linux-\(serverArch)"
        let binaryURL = Bundle.main.url(forResource: binaryName, withExtension: nil)

        if (action == .install || action == .updatePreserve), binaryURL == nil {
            throw DeployError.missingAsset(binaryName)
        }

        return DeployRequest(
            deployKind: selectedDeployKind.rawValue,
            action: action.rawValue,
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            user: user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "root" : user.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password,
            port: sshPort,
            deployScriptPath: scriptURL?.path ?? "",
            serverBinaryPath: binaryURL?.path ?? "",
            mainPassword: mainPassword,
            csqttTunnelPassword: csqttTunnelPassword,
            csqttWebUser: csqttWebUser.trimmingCharacters(in: .whitespacesAndNewlines),
            csqttWebPassword: csqttWebPassword,
            adminId: adminId.trimmingCharacters(in: .whitespacesAndNewlines),
            botToken: botToken.trimmingCharacters(in: .whitespacesAndNewlines),
            dtlsPort: effectiveDTLSPort,
            wgPort: effectiveWGPort,
            dns1: dns1.trimmingCharacters(in: .whitespacesAndNewlines),
            dns2: dns2.trimmingCharacters(in: .whitespacesAndNewlines),
            maxPasswords: maxPasswords,
            maxWorkersPerAccess: maxWorkersPerAccess,
            maxHandshakes: maxHandshakes,
            handshakeRate: handshakeRate,
            maxClientMbps: maxClientMbps,
            wdttExistingTunEnabled: wdttExistingTunEnabled,
            wdttExistingTunName: wdttExistingTunName.trimmingCharacters(in: .whitespacesAndNewlines),
            stateArchiveBase64: ""
        )
    }

    private func updateStatusIndicators(_ response: DeployResponse) {
        serverConnected = response.serverConnected
        wdttInstalled = response.wdttInstalled
        readyToConnect = response.readyToConnect
    }

    private func applyDiscoveredServerSettings(_ response: DeployResponse) {
        if let value = response.dtlsPort, isValidPort(value), value != dtlsPort {
            dtlsPort = value
            manualPorts = true
        }
        if let value = response.wgPort, isValidPort(value), value != wgPort {
            wgPort = value
            manualPorts = true
        }
        if dns1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let value = nonEmpty(response.dns1) {
            dns1 = value
        }
        if dns2.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let value = nonEmpty(response.dns2) {
            dns2 = value
        }
        if isWDTTFamily, mainPassword.isEmpty, let value = nonEmpty(response.mainPassword) {
            mainPassword = value
        }
        if selectedDeployKind == .csqtt, csqttTunnelPassword.isEmpty, let value = nonEmpty(response.csqttTunnelPassword) {
            csqttTunnelPassword = value
        }
        if selectedDeployKind == .csqtt, csqttWebPassword.isEmpty, let value = nonEmpty(response.csqttWebPassword) {
            csqttWebPassword = value
        }
        if selectedDeployKind == .csqtt,
           csqttWebUser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let value = nonEmpty(response.csqttWebUser) {
            csqttWebUser = value
        }
        if adminId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let value = nonEmpty(response.adminId) {
            adminId = value
        }
        if botToken.isEmpty, let value = nonEmpty(response.botToken) {
            botToken = value
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func isValidPort(_ value: Int) -> Bool {
        (1...65535).contains(value)
    }

    private func clearStatusIndicators() {
        serverConnected = nil
        wdttInstalled = nil
        readyToConnect = nil
    }

    private func syncVisiblePorts(for kind: DeployServerKind) {
        switch kind {
        case .wdtt:
            manualPorts = wdttManualPorts
            dtlsPort = wdttDtlsPort
            wgPort = wdttWgPort
        case .wdttPlus:
            manualPorts = wdttManualPorts
            dtlsPort = wdttDtlsPort
            wgPort = wdttWgPort
        case .csqtt:
            manualPorts = csqttManualPorts
            dtlsPort = csqttPeerPort
            wgPort = csqttWebPort
        }
        lastLoadedDeployKind = kind
    }

    private func persistVisiblePorts(for kind: DeployServerKind) {
        switch kind {
        case .wdtt:
            wdttManualPorts = manualPorts
            wdttDtlsPort = dtlsPort
            wdttWgPort = wgPort
        case .wdttPlus:
            wdttManualPorts = manualPorts
            wdttDtlsPort = dtlsPort
            wdttWgPort = wgPort
        case .csqtt:
            csqttManualPorts = manualPorts
            csqttPeerPort = dtlsPort
            csqttWebPort = wgPort
        }

        // Keep legacy shared keys aligned for compatibility with older installs/import flows.
        if kind == selectedDeployKind {
            manualPorts = manualPorts
            dtlsPort = dtlsPort
            wgPort = wgPort
        }
    }

    private func consumePendingLaunchActionIfNeeded() {
        guard !didConsumeLaunchAction else { return }
        didConsumeLaunchAction = true

        let actionValue = launchActionRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !actionValue.isEmpty else { return }
        launchActionRaw = ""

        guard isWDTTPlus, let action = DeployAction(rawValue: actionValue) else {
            return
        }

        switch action {
        case .updatePreserve:
            run(.updatePreserve)
        case .reinstall:
            run(.reinstall)
        default:
            break
        }
    }

    private var serverAdminTarget: ServerAdminTarget? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMainPassword = mainPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, !password.isEmpty, !trimmedMainPassword.isEmpty, isSSHPortValid else {
            return nil
        }
        return ServerAdminTarget(
            host: trimmedHost,
            user: trimmedUser.isEmpty ? "root" : trimmedUser,
            password: password,
            port: sshPort,
            mainPassword: trimmedMainPassword
        )
    }

    private var csqttAdminTarget: CSQTTAdminTarget? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedWebUser = csqttWebUser.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedWebPassword = csqttWebPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmedHost.isEmpty,
            !password.isEmpty,
            !trimmedWebUser.isEmpty,
            !trimmedWebPassword.isEmpty,
            isSSHPortValid,
            isValidPort(effectiveWGPort)
        else {
            return nil
        }
        return CSQTTAdminTarget(
            host: trimmedHost,
            user: trimmedUser.isEmpty ? "root" : trimmedUser,
            password: password,
            port: sshPort,
            webPort: effectiveWGPort,
            webUser: trimmedWebUser,
            webPassword: trimmedWebPassword
        )
    }

    private var serverManagementTarget: ServerManagementTarget? {
        switch selectedDeployKind {
        case .wdtt:
            guard let target = serverAdminTarget else { return nil }
            return .wdtt(target)
        case .wdttPlus:
            guard let target = serverAdminTarget else { return nil }
            return .wdtt(target)
        case .csqtt:
            guard let target = csqttAdminTarget else { return nil }
            return .csqtt(target)
        }
    }

    private var serverOutboundTarget: ServerOutboundTarget? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, !password.isEmpty, isSSHPortValid else {
            return nil
        }
        return ServerOutboundTarget(
            host: trimmedHost,
            user: trimmedUser.isEmpty ? "root" : trimmedUser,
            password: password,
            port: sshPort
        )
    }

    private var csqttWebPanelURL: URL? {
        guard selectedDeployKind == .csqtt else { return nil }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, isValidPort(effectiveWGPort) else { return nil }
        return URL(string: "http://\(trimmedHost):\(effectiveWGPort)")
    }

    private func openCSQTTWebPanel() {
        guard let url = csqttWebPanelURL else { return }
        openURL(url)
    }

    private func copyCSQTTWebPanelLink() {
        guard let url = csqttWebPanelURL else { return }
        UIPasteboard.general.string = url.absoluteString
        resultTitle = "Link Copied"
        resultMessage = "The CSQTT web panel link was copied to the clipboard."
        showAlert = true
    }

    @ViewBuilder
    private func secretField(_ title: String, text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            SecureField(title, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            copyButton(for: text.wrappedValue)
        }
    }

    @ViewBuilder
    private func copyableTextField(_ title: String, text: Binding<String>, keyboardType: UIKeyboardType = .default) -> some View {
        HStack(spacing: 12) {
            TextField(title, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(keyboardType)

            copyButton(for: text.wrappedValue)
        }
    }

    @ViewBuilder
    private func copyButton(for value: String) -> some View {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        Button {
            UIPasteboard.general.string = value
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.body)
        }
        .buttonStyle(.borderless)
        .disabled(trimmedValue.isEmpty)
        .accessibilityLabel("Copy")
    }

    private func writeExportedLogsFile(contents: String) -> URL? {
        guard !contents.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stamp = formatter.string(from: Date())
        let safeHost = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        let prefix = isWDTTFamily ? "\(selectedDeployKind.rawValue)-server-logs" : "csqtt-server-logs"
        let filename = "\(prefix)-\(safeHost.isEmpty ? "server" : safeHost)-\(stamp).log"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            SharedLogger.error("Failed to write exported server logs: \(error.localizedDescription)")
            resultTitle = "Export Failed"
            resultMessage = "Failed to prepare the exported server log file."
            showAlert = true
            return nil
        }
    }

    private func writeExportedStateFile(contents: String) -> URL? {
        guard let archive = extractExportedStateArchive(from: contents) else {
            resultTitle = "Export Failed"
            resultMessage = "Failed to extract server state archive from deploy output."
            showAlert = true
            return nil
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stamp = formatter.string(from: Date())
        let safeHost = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        let filename = "wdtt-server-state-\(safeHost.isEmpty ? "server" : safeHost)-\(stamp).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try archive.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            SharedLogger.error("Failed to write exported server state: \(error.localizedDescription)")
            resultTitle = "Export Failed"
            resultMessage = "Failed to prepare the exported server state file."
            showAlert = true
            return nil
        }
    }

    private func extractExportedStateArchive(from contents: String) -> String? {
        let marker = "== state archive =="
        guard let range = contents.range(of: marker) else {
            return nil
        }
        let suffix = contents[range.upperBound...]
        let trimmed = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let nextRange = trimmed.range(of: "\n== ") {
            return String(trimmed[..<nextRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private func importServerState(from url: URL) {
        guard !isRunning else { return }
        Task {
            do {
                let access = url.startAccessingSecurityScopedResource()
                defer {
                    if access {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                let data = try Data(contentsOf: url)
                guard let archive = String(data: data, encoding: .utf8) else {
                    throw NSError(domain: "DeployView", code: 1, userInfo: [NSLocalizedDescriptionKey: "The selected file is not valid UTF-8 text."])
                }

                var request = try makeRequest(.importState)
                request.stateArchiveBase64 = data.base64EncodedString()

                await MainActor.run {
                    isRunning = true
                    currentAction = .importState
                    output = ""
                }

                let response = await perform(request)
                await MainActor.run {
                    isRunning = false
                    currentAction = nil
                    output = response.output
                    updateStatusIndicators(response)
                    if response.ok {
                        applyDiscoveredServerSettings(response)
                    }
                    resultTitle = response.ok ? "Restore Complete" : "Restore Failed"
                    resultMessage = response.ok ? "Server backup was restored and applied." : response.message
                    showAlert = true
                    SharedLogger.info("WDTT server backup restore finished for archive size \(archive.count)")
                    if !response.output.isEmpty {
                        SharedLogger.info("WDTT deploy output:\n\(response.output)")
                    }
                }
            } catch {
                await MainActor.run {
                    resultTitle = "Restore Failed"
                    resultMessage = error.localizedDescription
                    showAlert = true
                }
            }
        }
    }
}

private struct DeployStatusRow: View {
    var title: String
    var value: Bool?
    var isChecking: Bool

    var body: some View {
        HStack {
            statusIcon
            Text(title)
            Spacer()
            if isChecking {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var statusIcon: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 10, height: 10)
            .accessibilityHidden(true)
    }

    private var statusColor: Color {
        guard !isChecking else { return .secondary }
        switch value {
        case .some(true):
            return .green
        case .some(false):
            return .red
        case .none:
            return .secondary
        }
    }
}

private enum DeployError: LocalizedError {
    case missingAsset(String)
    case invalidJSON
    case emptyResponse
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingAsset(let name):
            return "Missing deploy asset: \(name). Rebuild the app through GitHub Actions."
        case .invalidJSON:
            return "Failed to encode deploy request."
        case .emptyResponse:
            return "Deploy bridge returned an empty response."
        case .invalidResponse(let value):
            return "Deploy bridge returned an invalid response: \(String(value.prefix(160)))"
        }
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
