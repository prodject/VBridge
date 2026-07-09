import Foundation
import SwiftUI
import WireGuardKitGo

private enum DeployAction: String {
    case install
    case uninstall
    case status
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

                SecureField("SSH Password", text: $password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField("SSH Port", value: $sshPort, format: .number)
                    .keyboardType(.numberPad)

                if !isSSHPortValid {
                    Text("SSH port must be between 1 and 65535")
                        .font(.caption)
                        .foregroundColor(.red)
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
                SecureField("WDTT Main Password", text: $mainPassword)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                if !mainPassword.isEmpty && !isMainPasswordValid {
                    Text("Allowed: letters, digits, and _ . ! ? : # - /")
                        .font(.caption)
                        .foregroundColor(.red)
                }

                TextField("Telegram Admin ID", text: $adminId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numberPad)

                SecureField("Telegram Bot Token", text: $botToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section(header: Text("Ports")) {
                Toggle("Manual port control", isOn: $manualPorts)

                if manualPorts {
                    Stepper("DTLS Port: \(dtlsPort)", value: $dtlsPort, in: 1...65535)
                    Stepper("WireGuard Port: \(wgPort)", value: $wgPort, in: 1...65535)
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
    }

    private var effectiveDTLSPort: Int {
        manualPorts ? dtlsPort : 56000
    }

    private var effectiveWGPort: Int {
        manualPorts ? wgPort : 56001
    }

    private var canConnect: Bool {
        !isRunning && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty && isSSHPortValid
    }

    private var canInstall: Bool {
        canConnect && isMainPasswordValid
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
        guard let scriptURL = Bundle.main.url(forResource: "wdtt-deploy", withExtension: "sh") else {
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
            deployScriptPath: scriptURL.path,
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
