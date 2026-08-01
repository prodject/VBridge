import SwiftUI

struct OutboundManagementView: View {
    let target: ServerOutboundTarget?
    let canConnect: Bool

    @State private var output = ""
    @State private var resultTitle = ""
    @State private var resultMessage = ""
    @State private var showAlert = false
    @State private var isRunning = false
    @State private var currentAction = ""

    @State private var externalKind = "socks5"
    @State private var externalHost = ""
    @State private var externalPort = 1080
    @State private var externalLogin = ""
    @State private var externalPassword = ""

    @State private var localLogin = ""
    @State private var localPassword = ""
    @State private var localPort = 1080

    private let proxyKinds = ["socks5", "http"]

    var body: some View {
        Form {
            Section(header: Text("Status")) {
                Button {
                    run(.init(action: "status"))
                } label: {
                    Label(isRunning && currentAction == "status" ? "Refreshing..." : "Refresh Outbound Status", systemImage: "arrow.clockwise")
                }
                .disabled(!canConnect || isRunning)

                Button {
                    run(.init(action: "diagnostics"))
                } label: {
                    Label(isRunning && currentAction == "diagnostics" ? "Checking..." : "Diagnostics", systemImage: "stethoscope")
                }
                .disabled(!canConnect || isRunning)
            }

            Section(header: Text("External TCP Proxy")) {
                Picker("Proxy Type", selection: $externalKind) {
                    ForEach(proxyKinds, id: \.self) { kind in
                        Text(kind.uppercased()).tag(kind)
                    }
                }
                TextField("Proxy Host", text: $externalHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Proxy Port", value: $externalPort, format: .number)
                    .keyboardType(.numberPad)
                TextField("Proxy Login", text: $externalLogin)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Proxy Password", text: $externalPassword)

                Button("Check Proxy") {
                    run(.init(
                        action: "external_check",
                        kind: externalKind,
                        proxyHost: externalHost.trimmingCharacters(in: .whitespacesAndNewlines),
                        proxyPort: externalPort,
                        login: externalLogin.trimmingCharacters(in: .whitespacesAndNewlines),
                        secret: externalPassword
                    ))
                }
                .disabled(!canConnect || isRunning || externalHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Enable External Proxy") {
                    run(.init(
                        action: "external_enable",
                        kind: externalKind,
                        proxyHost: externalHost.trimmingCharacters(in: .whitespacesAndNewlines),
                        proxyPort: externalPort,
                        login: externalLogin.trimmingCharacters(in: .whitespacesAndNewlines),
                        secret: externalPassword
                    ))
                }
                .disabled(!canConnect || isRunning || externalHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Section(header: Text("Local Proxy On This VPS")) {
                TextField("Proxy Login", text: $localLogin)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Proxy Password", text: $localPassword)
                TextField("SOCKS5 Port", value: $localPort, format: .number)
                    .keyboardType(.numberPad)

                Button("Install / Update Local Proxy") {
                    run(.init(
                        action: "local_install",
                        login: localLogin.trimmingCharacters(in: .whitespacesAndNewlines),
                        secret: localPassword,
                        localPort: localPort
                    ))
                }
                .disabled(!canConnect || isRunning || localLogin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || localPassword.isEmpty)

                Button("Check Local Proxy") {
                    run(.init(action: "local_check"))
                }
                .disabled(!canConnect || isRunning)

                Button("Stop Local Proxy") {
                    run(.init(action: "local_stop"))
                }
                .disabled(!canConnect || isRunning)

                Button("Remove Local Proxy", role: .destructive) {
                    run(.init(action: "local_remove"))
                }
                .disabled(!canConnect || isRunning)
            }

            Section(header: Text("Free WARP")) {
                Button("Check WARP") {
                    run(.init(action: "warp_check"))
                }
                .disabled(!canConnect || isRunning)

                Button("Restart and Check WARP") {
                    run(.init(action: "warp_restart"))
                }
                .disabled(!canConnect || isRunning)

                Button("Delete WARP", role: .destructive) {
                    run(.init(action: "warp_delete"))
                }
                .disabled(!canConnect || isRunning)
            }

            Section(header: Text("Direct")) {
                Button("Restore Direct Outbound") {
                    run(.init(action: "direct"))
                }
                .disabled(!canConnect || isRunning)
            }

            Section(header: Text("Other Server")) {
                Text("WireGuard outbound through another server is not yet exposed in iOS. The current bridge covers direct mode, local proxy, external TCP proxy, and existing Free WARP management.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if !output.isEmpty {
                Section(header: Text("Output")) {
                    ScrollView(.vertical) {
                        Text(output)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 180)
                }
            }
        }
        .navigationTitle("Outbound")
        .navigationBarTitleDisplayMode(.inline)
        .alert(resultTitle, isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(resultMessage)
        }
        .task {
            if output.isEmpty {
                run(.init(action: "status"))
            }
        }
    }

    private func run(_ request: ServerOutboundRequest) {
        guard let target, canConnect, !isRunning else { return }
        isRunning = true
        currentAction = request.action
        Task {
            do {
                let response = try await ServerOutboundBridge.run(target, request: request)
                await MainActor.run {
                    isRunning = false
                    currentAction = ""
                    output = response.output
                    resultTitle = "Outbound Complete"
                    resultMessage = response.message
                    showAlert = true
                }
            } catch {
                await MainActor.run {
                    isRunning = false
                    currentAction = ""
                    resultTitle = "Outbound Failed"
                    resultMessage = error.localizedDescription
                    showAlert = true
                }
            }
        }
    }
}
