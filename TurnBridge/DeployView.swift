import Foundation
import SwiftUI
import UIKit
import WireGuardKitGo

private enum DeployAction: String, Sendable {
    case install
    case reinstall
    case uninstall
    case status
    case exportLogs = "export_logs"
    case cleanupDevices = "cleanup_devices"
}

private struct DeployRequest: Encodable, Sendable {
    var action: String
    var host: String
    var user: String
    var password: String
    var port: Int
    var deployScriptPath: String
    var serverBinaryPath: String
    var mainPassword: String
    var adminId: String
    var botToken: String
    var dtlsPort: Int
    var wgPort: Int
    var dns1: String
    var dns2: String
}

private struct DeployResponse: Decodable, Sendable {
    var ok: Bool
    var status: String
    var message: String
    var output: String
    var serverConnected: Bool?
    var wdttInstalled: Bool?
    var readyToConnect: Bool?
    var dtlsPort: Int?
    var wgPort: Int?
    var dns1: String?
    var dns2: String?
    var mainPassword: String?
    var adminId: String?
    var botToken: String?
}

struct DeployView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("deploy.host") private var host = ""
    @AppStorage("deploy.user") private var user = "root"
    @AppStorage("deploy.password") private var password = ""
    @AppStorage("deploy.sshPort") private var sshPort = 22
    @AppStorage("deploy.dns1") private var dns1 = "1.1.1.1"
    @AppStorage("deploy.dns2") private var dns2 = "1.0.0.1"
    @AppStorage("deploy.mainPassword") private var mainPassword = ""
    @AppStorage("deploy.adminId") private var adminId = ""
    @AppStorage("deploy.botToken") private var botToken = ""
    @AppStorage("deploy.manualPorts") private var manualPorts = false
    @AppStorage("deploy.dtlsPort") private var dtlsPort = 56000
    @AppStorage("deploy.wgPort") private var wgPort = 56001
    @AppStorage("deploy.serverArch") private var serverArch = "amd64"

    @State private var isRunning = false
    @State private var currentAction: DeployAction?
    @State private var resultTitle = ""
    @State private var resultMessage = ""
    @State private var output = ""
    @State private var showAlert = false
    @State private var showCleanupConfirmation = false
    @State private var showExportConfirmation = false
    @State private var showReinstallConfirmation = false
    @State private var exportedLogsURL: URL?
    @State private var shareLogsURL: URL?
    @State private var isCheckingServerStatus = false
    @State private var serverConnected: Bool?
    @State private var wdttInstalled: Bool?
    @State private var readyToConnect: Bool?
    @State private var isLoadingClients = false
    @State private var serverClients: [ServerAdminClientInfo] = []
    @State private var showCreateClientSheet = false
    @State private var newClientLabel = ""
    @State private var newClientHash = ""
    @State private var newClientPorts = "56000,56001,9000"
    @State private var newClientDays = 30
    @State private var newClientPassword = ""

    private let serverArchitectures = ["amd64", "arm64"]

    var body: some View {
        Form {
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
                    DeployStatusRow(title: "WDTT installed", value: wdttInstalled, isChecking: isCheckingServerStatus)
                    DeployStatusRow(title: "Ready to connect", value: readyToConnect, isChecking: isCheckingServerStatus)
                }

                Section(header: Text("Server Clients")) {
                    HStack {
                        Button {
                            refreshServerClients()
                        } label: {
                            Label(isLoadingClients ? "Refreshing..." : "Refresh Clients", systemImage: "arrow.clockwise")
                        }
                        .disabled(!canConnect || isLoadingClients)

                        Spacer()

                        Button {
                            showCreateClientSheet = true
                        } label: {
                            Label("New Client", systemImage: "plus")
                        }
                        .disabled(!canConnect || mainPassword.isEmpty)
                    }

                    if serverClients.isEmpty {
                        Text(isLoadingClients ? "Loading clients..." : "No clients loaded.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(serverClients) { client in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(client.title)
                                            .font(.headline)
                                        Text(client.password)
                                            .font(.caption.monospaced())
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Text(client.status)
                                        .font(.caption)
                                        .foregroundColor(client.isActive ? .green : .orange)
                                }

                                if let ports = client.ports, !ports.isEmpty {
                                    Text("Ports: \(ports)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack {
                                        Button(client.isActive ? "Deactivate" : "Activate") {
                                            runServerClientAction(client.isActive ? .deactivate : .activate, clientPassword: client.password)
                                        }
                                        .buttonStyle(.bordered)

                                        Button("Unbind") {
                                            runServerClientAction(.unbind, clientPassword: client.password)
                                        }
                                        .buttonStyle(.bordered)

                                        Button("Delete", role: .destructive) {
                                            runServerClientAction(.delete, clientPassword: client.password)
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }

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

            Section(header: Text("Secrets")) {
                secretField("WDTT Main Password", text: $mainPassword)

                if !mainPassword.isEmpty && !isMainPasswordValid {
                    Text("Allowed: letters, digits, and _ . ! ? : # - /")
                        .font(.caption)
                        .foregroundColor(.red)
                }

                copyableTextField("Telegram Admin ID", text: $adminId, keyboardType: .numberPad)

                secretField("Telegram Bot Token", text: $botToken)
            }

            Section(header: Text("Ports")) {
                Toggle("Manual port control", isOn: $manualPorts)

                if manualPorts {
                    TextField("DTLS Port", value: $dtlsPort, format: .number)
                        .keyboardType(.numberPad)
                    TextField("WireGuard Port", value: $wgPort, format: .number)
                        .keyboardType(.numberPad)

                    if !isValidPort(dtlsPort) {
                        Text("DTLS port must be between 1 and 65535")
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    if !isValidPort(wgPort) {
                        Text("WireGuard port must be between 1 and 65535")
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
                Button {
                    showExportConfirmation = true
                } label: {
                    Label("Export Server", systemImage: "link.badge.plus")
                }
                .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !isSSHPortValid)

                Button {
                    run(.exportLogs)
                } label: {
                    Label(isRunning && currentAction == .exportLogs ? "Exporting Logs..." : "Export Logs", systemImage: "square.and.arrow.up")
                }
                .disabled(!canConnect)

                Button {
                    run(.install)
                } label: {
                    Label(isRunning && currentAction == .install ? "Installing..." : "Install", systemImage: "icloud.and.arrow.up")
                }
                .disabled(!canInstall)

                Button {
                    run(.status)
                } label: {
                    Label(isRunning && currentAction == .status ? "Checking..." : "Status", systemImage: "waveform.path.ecg")
                }
                .disabled(!canConnect)

                Button(role: .destructive) {
                    showCleanupConfirmation = true
                } label: {
                    Label(isRunning && currentAction == .cleanupDevices ? "Cleaning..." : "Clean Orphan Devices", systemImage: "externaldrive.badge.xmark")
                }
                .disabled(!canConnect)

                Button(role: .destructive) {
                    showReinstallConfirmation = true
                } label: {
                    Label(isRunning && currentAction == .reinstall ? "Reinstalling..." : "Reinstall", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!canInstall)

                Button(role: .destructive) {
                    run(.uninstall)
                } label: {
                    Label(isRunning && currentAction == .uninstall ? "Removing..." : "Uninstall", systemImage: "trash")
                }
                .disabled(!canConnect)
            }

            if isRunning {
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
            "Reinstall WDTT on the server?",
            isPresented: $showReinstallConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reinstall", role: .destructive) {
                run(.reinstall)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The app will uninstall WDTT from the server and then install it again using the current Deploy settings, including ports, DNS, and saved secrets.")
        }
        .task {
            await refreshSavedServerStatus()
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
        .sheet(isPresented: $showCreateClientSheet) {
            NavigationStack {
                Form {
                    Section(header: Text("Client")) {
                        TextField("Label", text: $newClientLabel)
                        TextField("VK Hash", text: $newClientHash)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Ports", text: $newClientPorts)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Password", text: $newClientPassword)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Stepper("Days: \(newClientDays)", value: $newClientDays, in: 0...365)
                    }

                    Section {
                        Button("Create Client") {
                            createServerClient()
                        }
                        .disabled(!canConnect || mainPassword.isEmpty)
                    }
                }
                .navigationTitle("New Client")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            showCreateClientSheet = false
                        }
                    }
                }
            }
        }
    }

    private var effectiveDTLSPort: Int {
        manualPorts ? dtlsPort : 56000
    }

    private var effectiveWGPort: Int {
        manualPorts ? wgPort : 56001
    }

    private var canConnect: Bool {
        !isRunning && !isCheckingServerStatus && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty && isSSHPortValid
    }

    private var hasSavedServerSettings: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    private var canInstall: Bool {
        canConnect && isMainPasswordValid && isValidPort(effectiveDTLSPort) && isValidPort(effectiveWGPort)
    }

    private var isMainPasswordValid: Bool {
        let pattern = #"^[a-zA-Z0-9_.!?:#/-]+$"#
        return mainPassword.range(of: pattern, options: .regularExpression) != nil
    }

    private var isSSHPortValid: Bool {
        (1...65535).contains(sshPort)
    }

    private func run(_ action: DeployAction) {
        guard !isRunning else { return }
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

        Task {
            let response = await perform(request)
            await MainActor.run {
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
                resultTitle = response.ok ? "Deploy Complete" : "Deploy Failed"
                resultMessage = response.message
                showAlert = true

                if response.ok {
                    SharedLogger.info("WDTT deploy \(action.rawValue) completed")
                } else {
                    SharedLogger.error("WDTT deploy \(action.rawValue) failed: \(response.message)")
                }
                if !response.output.isEmpty {
                    SharedLogger.info("WDTT deploy output:\n\(response.output)")
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
                    isRunning = false
                    currentAction = nil
                    output = combinedOutput
                    updateStatusIndicators(uninstallResponse)
                    resultTitle = "Reinstall Failed"
                    resultMessage = "Uninstall step failed: \(uninstallResponse.message)"
                    showAlert = true
                    SharedLogger.error("WDTT reinstall failed during uninstall: \(uninstallResponse.message)")
                    if !combinedOutput.isEmpty {
                        SharedLogger.info("WDTT reinstall output:\n\(combinedOutput)")
                    }
                }
                return
            }

            let installResponse = await perform(installRequest)
            combinedOutput += "== reinstall: install ==\n"
            if installResponse.output.isEmpty {
                combinedOutput += installResponse.message
            } else {
                combinedOutput += installResponse.output
            }

            await MainActor.run {
                isRunning = false
                currentAction = nil
                output = combinedOutput
                updateStatusIndicators(installResponse)
                if installResponse.ok {
                    applyDiscoveredServerSettings(installResponse)
                    resultTitle = "Reinstall Complete"
                    resultMessage = "WDTT was reinstalled with the current Deploy settings."
                    SharedLogger.info("WDTT reinstall completed")
                } else {
                    resultTitle = "Reinstall Failed"
                    resultMessage = "Install step failed: \(installResponse.message)"
                    SharedLogger.error("WDTT reinstall failed during install: \(installResponse.message)")
                }
                showAlert = true
                if !combinedOutput.isEmpty {
                    SharedLogger.info("WDTT reinstall output:\n\(combinedOutput)")
                }
            }
        }
    }

    private func exportServerSettings() {
        let settings = DeploySettingsLink(
            version: 1,
            nonce: UUID(),
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            user: user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "root" : user.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password,
            sshPort: sshPort,
            dns1: dns1,
            dns2: dns2,
            mainPassword: mainPassword,
            adminId: adminId,
            botToken: botToken,
            manualPorts: manualPorts,
            dtlsPort: dtlsPort,
            wgPort: wgPort,
            serverArch: serverArch
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

    private func makeRequest(_ action: DeployAction) throws -> DeployRequest {
        let scriptURL = Bundle.main.url(forResource: "wdtt-deploy", withExtension: "sh")
        if action == .install || action == .uninstall, scriptURL == nil {
            throw DeployError.missingAsset("wdtt-deploy.sh")
        }

        let binaryName = "wdtt-server-linux-\(serverArch)"
        let binaryURL = Bundle.main.url(forResource: binaryName, withExtension: nil)

        if action == .install, binaryURL == nil {
            throw DeployError.missingAsset(binaryName)
        }

        return DeployRequest(
            action: action.rawValue,
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            user: user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "root" : user.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password,
            port: sshPort,
            deployScriptPath: scriptURL?.path ?? "",
            serverBinaryPath: binaryURL?.path ?? "",
            mainPassword: mainPassword,
            adminId: adminId.trimmingCharacters(in: .whitespacesAndNewlines),
            botToken: botToken.trimmingCharacters(in: .whitespacesAndNewlines),
            dtlsPort: effectiveDTLSPort,
            wgPort: effectiveWGPort,
            dns1: dns1.trimmingCharacters(in: .whitespacesAndNewlines),
            dns2: dns2.trimmingCharacters(in: .whitespacesAndNewlines)
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
        if mainPassword.isEmpty, let value = nonEmpty(response.mainPassword) {
            mainPassword = value
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

    private func refreshServerClients() {
        guard let target = serverAdminTarget, !isLoadingClients else { return }
        isLoadingClients = true
        Task {
            do {
                let clients = try await ServerAdminBridge.list(target)
                await MainActor.run {
                    serverClients = clients.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                    isLoadingClients = false
                }
            } catch {
                await MainActor.run {
                    isLoadingClients = false
                    resultTitle = "Clients Refresh Failed"
                    resultMessage = error.localizedDescription
                    showAlert = true
                }
            }
        }
    }

    private func createServerClient() {
        guard let target = serverAdminTarget else { return }
        let request = ServerAdminCreateRequest(
            label: newClientLabel.trimmingCharacters(in: .whitespacesAndNewlines),
            vkHash: newClientHash.trimmingCharacters(in: .whitespacesAndNewlines),
            ports: newClientPorts.trimmingCharacters(in: .whitespacesAndNewlines),
            days: newClientDays,
            clientPassword: newClientPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        Task {
            do {
                _ = try await ServerAdminBridge.create(target, request: request)
                await MainActor.run {
                    newClientLabel = ""
                    newClientHash = ""
                    newClientPorts = "56000,56001,9000"
                    newClientDays = 30
                    newClientPassword = ""
                    showCreateClientSheet = false
                    refreshServerClients()
                }
            } catch {
                await MainActor.run {
                    resultTitle = "Create Client Failed"
                    resultMessage = error.localizedDescription
                    showAlert = true
                }
            }
        }
    }

    private func runServerClientAction(_ action: ServerAdminAction, clientPassword: String) {
        guard let target = serverAdminTarget else { return }
        Task {
            do {
                _ = try await ServerAdminBridge.run(action, target: target, clientPassword: clientPassword)
                await MainActor.run {
                    refreshServerClients()
                }
            } catch {
                await MainActor.run {
                    resultTitle = "Client Action Failed"
                    resultMessage = error.localizedDescription
                    showAlert = true
                }
            }
        }
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
        let filename = "wdtt-server-logs-\(safeHost.isEmpty ? "server" : safeHost)-\(stamp).log"
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
