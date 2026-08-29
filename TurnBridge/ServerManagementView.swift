import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import CoreImage.CIFilterBuiltins
import Security

struct ServerManagementView: View {
    let target: ServerManagementTarget?
    let canConnect: Bool

    @State private var isLoadingClients = false
    @State private var serverClients: [ServerAdminClientInfo] = []
    @State private var showCreateClientSheet = false
    @State private var editingClient: ServerAdminClientInfo?
    @State private var newClientLabel = ""
    @State private var newClientHash = ""
    @State private var newClientPorts = "56000,56001,9000"
    @State private var newClientDays = 30
    @State private var newClientPassword = ""
    @State private var editedLabel = ""
    @State private var editedHash = ""
    @State private var editedPorts = "56000,56001,9000"
    @State private var editedExpiryDays = 30
    @State private var editedNeverExpires = false
    @State private var editedNewPassword = ""
    @State private var resultTitle = ""
    @State private var resultMessage = ""
    @State private var showAlert = false
    @State private var showImportPicker = false
    @State private var shareItems: [Any] = []
    @State private var copiedCurrentPassword = false
    private let clientDurationOptions: [(title: String, value: Int)] = [
        ("30", 30),
        ("180", 180),
        ("365", 365),
        ("Unlimited", 0)
    ]

    var body: some View {
        Form {
            Section(header: Text("Clients")) {
                HStack {
                    Button {
                        refreshServerClients()
                    } label: {
                        Text(isLoadingClients ? "Refreshing..." : "Refresh")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!canManage || isLoadingClients)

                    Spacer()

                    Button {
                        newClientPorts = defaultPortsValue
                        showCreateClientSheet = true
                    } label: {
                        Text("New")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!canManage)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

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

                            Text(expiryText(for: client))
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Text(trafficText(for: client))
                                .font(.caption)
                                .foregroundColor(.secondary)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack {
                                    Button("Edit") {
                                        beginEditing(client)
                                    }
                                    .buttonStyle(.bordered)

                    Button("Share") {
                        shareClient(client)
                    }
                    .buttonStyle(.bordered)

                                    Button("Quick Link") {
                                        shareQuickLink(client)
                                    }
                                    .buttonStyle(.bordered)

                                    Button("QR") {
                                        shareClientQR(client)
                                    }
                                    .buttonStyle(.bordered)

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

            if canManage && isWDTTManagement {
                Section(header: Text("Extended")) {
                    Button("Cleanup Expired") {
                        runGlobalAction(.cleanupExpired)
                    }
                    .disabled(!canManage)

                    Button("Cleanup Orphans") {
                        runGlobalAction(.cleanupOrphans)
                    }
                    .disabled(!canManage)

                    Button("Export Clients") {
                        exportClients()
                    }
                    .disabled(!canManage || serverClients.isEmpty)

                    Button("Import Client") {
                        showImportPicker = true
                    }
                    .disabled(!canManage)
                }
            }

            if !canManage {
                Section {
                    Text(managementRequirementsText)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("Management")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            refreshServerClients()
        }
        .alert(resultTitle, isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(resultMessage)
        }
        .sheet(isPresented: Binding(
            get: { !shareItems.isEmpty },
            set: { isPresented in
                if !isPresented {
                    shareItems = []
                }
            }
        )) {
            if !shareItems.isEmpty {
                ServerManagementActivityView(items: shareItems)
            }
        }
        .sheet(isPresented: $showImportPicker) {
            DocumentPicker(
                contentTypes: [.json, .plainText, .text],
                onPick: { url in
                    showImportPicker = false
                    importClient(from: url)
                },
                onCancel: {
                    showImportPicker = false
                }
            )
        }
        .sheet(isPresented: $showCreateClientSheet) {
            NavigationStack {
                Form {
                    Section(header: Text("Client")) {
                        TextField("Label", text: $newClientLabel)
                        if isWDTTManagement {
                            TextField("VK Hash (optional)", text: $newClientHash)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        TextField("Ports", text: $newClientPorts)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if isWDTTManagement {
                            VStack(alignment: .leading, spacing: 8) {
                                TextField("Password", text: $newClientPassword)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                Button("Generate") {
                                    newClientPassword = generateClientPassword()
                                }
                                .font(.caption)
                                .buttonStyle(.bordered)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Duration")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            HStack {
                                ForEach(clientDurationOptions, id: \.value) { option in
                                    Button(option.title) {
                                        newClientDays = option.value
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(newClientDays == option.value ? .accentColor : .gray.opacity(0.35))
                                }
                            }
                        }
                    }

                    Section {
                        Button("Create Client") {
                            createServerClient()
                        }
                        .disabled(!canManage)
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
        .sheet(item: $editingClient) { client in
            NavigationStack {
                Form {
                    Section(header: Text("Client")) {
                        HStack {
                            Text(String(repeating: "•", count: max(8, client.password.count)))
                                .font(.caption.monospaced())
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Copy") {
                                UIPasteboard.general.string = client.password
                                copiedCurrentPassword = true
                            }
                            .buttonStyle(.bordered)
                        }
                        TextField("Label", text: $editedLabel)
                        if isWDTTManagement {
                            TextField("VK Hash (optional)", text: $editedHash)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        TextField("Ports", text: $editedPorts)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    Section(header: Text("Expiry")) {
                        Toggle("Never Expires", isOn: $editedNeverExpires)
                        if !editedNeverExpires {
                            Stepper("Days: \(editedExpiryDays)", value: $editedExpiryDays, in: 1...365)
                        }
                    }

                    if isWDTTManagement {
                        Section(header: Text("Password")) {
                            VStack(alignment: .leading, spacing: 8) {
                                TextField("New Password", text: $editedNewPassword)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                Button("Generate") {
                                    editedNewPassword = generateClientPassword()
                                }
                                .font(.caption)
                                .buttonStyle(.bordered)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                    }

                    Section {
                        Button("Save Changes") {
                            saveClientEdits(client)
                        }
                        .disabled(!canManage)
                    }
                }
                .navigationTitle("Edit Client")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            editingClient = nil
                        }
                    }
                }
            }
        }
        .alert("Password Copied", isPresented: $copiedCurrentPassword) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The current client password was copied to the clipboard.")
        }
    }

    private var canManage: Bool {
        canConnect && target != nil
    }

    private var isWDTTManagement: Bool {
        if case .some(.wdtt) = target {
            return true
        }
        return false
    }

    private var managementRequirementsText: String {
        if isWDTTManagement {
            return "Fill in server host, SSH password, and WDTT main password in Deploy before opening management."
        }
        return "Fill in server host, SSH password, CSQTT web login, and CSQTT web password in Deploy before opening management."
    }

    private func refreshServerClients() {
        guard let target, !isLoadingClients else { return }
        isLoadingClients = true
        Task {
            do {
                let clients: [ServerAdminClientInfo]
                switch target {
                case .wdtt(let wdttTarget):
                    clients = try await ServerAdminBridge.list(wdttTarget)
                case .csqtt(let csqttTarget):
                    clients = try await CSQTTAdminBridge.list(csqttTarget)
                }
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
        guard let target else { return }
        let trimmedLabel = newClientLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHash = newClientHash.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPorts = normalizedPortsInput(newClientPorts)
        let trimmedPassword = newClientPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                switch target {
                case .wdtt(let wdttTarget):
                    _ = try await ServerAdminBridge.create(wdttTarget, request: ServerAdminCreateRequest(
                        label: trimmedLabel,
                        vkHash: trimmedHash,
                        ports: trimmedPorts,
                        days: newClientDays,
                        clientPassword: trimmedPassword
                    ))
                case .csqtt(let csqttTarget):
                    _ = try await CSQTTAdminBridge.create(csqttTarget, label: trimmedLabel, ports: trimmedPorts, days: newClientDays)
                }
                await MainActor.run {
                    newClientLabel = ""
                    newClientHash = ""
                    newClientPorts = defaultPortsValue
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

    private func beginEditing(_ client: ServerAdminClientInfo) {
        editingClient = client
        editedLabel = client.label ?? ""
        editedHash = client.vkHash ?? ""
        editedPorts = client.ports ?? defaultPortsValue
        editedNewPassword = ""
        if let expiresAt = client.expiresAt, expiresAt > 0 {
            let now = Int64(Date().timeIntervalSince1970)
            let seconds = max(Int64(0), expiresAt - now)
            editedExpiryDays = max(1, Int(ceil(Double(seconds) / 86400.0)))
            editedNeverExpires = false
        } else {
            editedExpiryDays = 30
            editedNeverExpires = true
        }
    }

    private func saveClientEdits(_ client: ServerAdminClientInfo) {
        guard let target else { return }
        let trimmedPassword = editedNewPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLabel = editedLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHash = editedHash.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPorts = normalizedPortsInput(editedPorts)
        let currentExpiresAt = client.expiresAt ?? 0
        let expiryNeedsUpdate: Bool = {
            if editedNeverExpires {
                return currentExpiresAt != 0
            }
            guard currentExpiresAt > 0 else { return true }
            let currentDays = max(1, Int(ceil(Double(max(0, currentExpiresAt - Int64(Date().timeIntervalSince1970))) / 86400.0)))
            return currentDays != editedExpiryDays
        }()
        let detailsNeedUpdate =
            trimmedLabel != (client.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines) ||
            trimmedHash != (client.vkHash ?? "").trimmingCharacters(in: .whitespacesAndNewlines) ||
            trimmedPorts != (client.ports ?? defaultPortsValue).trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                switch target {
                case .wdtt(let wdttTarget):
                    if detailsNeedUpdate {
                        _ = try await ServerAdminBridge.update(wdttTarget, request: ServerAdminUpdateRequest(
                            clientPassword: client.password,
                            label: trimmedLabel,
                            vkHash: trimmedHash,
                            ports: trimmedPorts,
                            days: nil,
                            expiresAt: nil,
                            newPassword: ""
                        ))
                    }

                    if expiryNeedsUpdate {
                        _ = try await ServerAdminBridge.setExpiry(
                            wdttTarget,
                            clientPassword: client.password,
                            days: editedNeverExpires ? nil : editedExpiryDays,
                            expiresAt: editedNeverExpires ? 0 : nil
                        )
                    }

                    if !trimmedPassword.isEmpty {
                        _ = try await ServerAdminBridge.setPassword(
                            wdttTarget,
                            clientPassword: client.password,
                            newPassword: trimmedPassword
                        )
                    }
                case .csqtt(let csqttTarget):
                    let days = editedNeverExpires ? 0 : editedExpiryDays
                    _ = try await CSQTTAdminBridge.update(csqttTarget, clientPassword: client.password, label: trimmedLabel, ports: trimmedPorts, days: days)
                }

                await MainActor.run {
                    editingClient = nil
                    refreshServerClients()
                }
            } catch {
                await MainActor.run {
                    resultTitle = "Update Client Failed"
                    resultMessage = error.localizedDescription
                    showAlert = true
                }
            }
        }
    }

    private func runServerClientAction(_ action: ServerAdminAction, clientPassword: String) {
        guard let target else { return }
        Task {
            do {
                switch target {
                case .wdtt(let wdttTarget):
                    _ = try await ServerAdminBridge.run(action, target: wdttTarget, clientPassword: clientPassword)
                case .csqtt(let csqttTarget):
                    let csqttAction: CSQTTAdminAction = (action == .unbind) ? .unbind : (action == .delete ? .delete : (action == .activate ? .activate : .deactivate))
                    _ = try await CSQTTAdminBridge.run(csqttAction, target: csqttTarget, clientPassword: clientPassword)
                }
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

    private func runGlobalAction(_ action: ServerAdminAction) {
        guard let target else { return }
        Task {
            do {
                guard case .wdtt(let wdttTarget) = target else { return }
                let response = try await ServerAdminBridge.run(action, target: wdttTarget)
                await MainActor.run {
                    resultTitle = "Management Complete"
                    resultMessage = response.message
                    showAlert = true
                    refreshServerClients()
                }
            } catch {
                await MainActor.run {
                    resultTitle = "Management Failed"
                    resultMessage = error.localizedDescription
                    showAlert = true
                }
            }
        }
    }

    private func shareClient(_ client: ServerAdminClientInfo) {
        switch target {
        case .wdtt:
            do {
                let transfer = try ServerAdminBridge.exportClient(client)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("wdtt-client-\(client.password).json")
                try transfer.write(to: url, atomically: true, encoding: .utf8)
                shareItems = [url]
            } catch {
                resultTitle = "Export Failed"
                resultMessage = error.localizedDescription
                showAlert = true
            }
        case .csqtt(let csqttTarget):
            guard let link = CSQTTAdminBridge.quickLink(csqttTarget, client: client) else {
                resultTitle = "Share Failed"
                resultMessage = "This client does not have enough data for a quick link."
                showAlert = true
                return
            }
            shareItems = [link]
        case .none:
            return
        }
    }

    private func shareQuickLink(_ client: ServerAdminClientInfo) {
        guard let link = quickLink(for: client) else {
            resultTitle = "Share Failed"
            resultMessage = "This client does not have enough data for a quick link."
            showAlert = true
            return
        }
        shareItems = [link]
    }

    private func shareClientQR(_ client: ServerAdminClientInfo) {
        guard let link = quickLink(for: client) else {
            resultTitle = "QR Failed"
            resultMessage = "This client does not have enough data for a quick link."
            showAlert = true
            return
        }
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(Data(link.utf8), forKey: "inputMessage")
        guard let outputImage = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cgImage = context.createCGImage(outputImage, from: outputImage.extent) else {
            resultTitle = "QR Failed"
            resultMessage = "Failed to generate the QR image."
            showAlert = true
            return
        }
        let image = UIImage(cgImage: cgImage)
        guard let data = image.pngData() else {
            resultTitle = "QR Failed"
            resultMessage = "Failed to encode the QR image."
            showAlert = true
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wdtt-client-\(client.password)-qr.png")
        do {
            try data.write(to: url)
            shareItems = [url]
        } catch {
            resultTitle = "QR Failed"
            resultMessage = error.localizedDescription
            showAlert = true
        }
    }

    private func importClient(from url: URL) {
        guard let target else { return }
        Task {
            do {
                guard case .wdtt(let wdttTarget) = target else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer {
                    if access {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                let data = try Data(contentsOf: url)
                guard let text = String(data: data, encoding: .utf8) else {
                    throw NSError(domain: "ServerManagementView", code: 1, userInfo: [NSLocalizedDescriptionKey: "The selected file is not valid UTF-8 text."])
                }
                let response = try await ServerAdminBridge.importClient(wdttTarget, transferText: text)
                await MainActor.run {
                    resultTitle = "Import Complete"
                    resultMessage = response.message
                    showAlert = true
                    refreshServerClients()
                }
            } catch {
                await MainActor.run {
                    resultTitle = "Import Failed"
                    resultMessage = error.localizedDescription
                    showAlert = true
                }
            }
        }
    }

    private func exportClients() {
        guard let target, !serverClients.isEmpty else { return }

        do {
            let text: String
            let filenamePrefix: String

            switch target {
            case .wdtt:
                text = try ServerAdminBridge.exportClients(serverClients)
                filenamePrefix = "wdtt-clients"
            case .csqtt:
                text = try CSQTTAdminBridge.exportClients(serverClients)
                filenamePrefix = "csqtt-clients"
            }

            let timestamp = ISO8601DateFormatter.compactFileNameTimestamp.string(from: Date())
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(filenamePrefix)-\(timestamp).json")
            try text.write(to: url, atomically: true, encoding: .utf8)
            shareItems = [url]
        } catch {
            resultTitle = "Export Failed"
            resultMessage = error.localizedDescription
            showAlert = true
        }
    }

    private func quickLink(for client: ServerAdminClientInfo) -> String? {
        guard let target else {
            return nil
        }
        if case .csqtt(let csqttTarget) = target {
            return CSQTTAdminBridge.quickLink(csqttTarget, client: client)
        }
        guard case .wdtt(let wdttTarget) = target else { return nil }
        let rawHash = client.vkHash?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ports = (client.ports?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? client.ports! : "56000,56001,9000")
        let parts = ports.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 3 else { return nil }
        var components = URLComponents()
        components.scheme = "wdtt"
        components.host = "connect"
        var queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "host", value: wdttTarget.host),
            URLQueryItem(name: "dtls", value: parts[0]),
            URLQueryItem(name: "wg", value: parts[1]),
            URLQueryItem(name: "local", value: parts[2]),
            URLQueryItem(name: "password", value: client.password)
        ]
        if !rawHash.isEmpty {
            queryItems.append(URLQueryItem(name: "hashes", value: rawHash))
        }
        if let label = client.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            queryItems.append(URLQueryItem(name: "name", value: label))
        }
        components.queryItems = queryItems
        return components.url?.absoluteString
    }

    private func expiryText(for client: ServerAdminClientInfo) -> String {
        guard let expiresAt = client.expiresAt, expiresAt > 0 else {
            return "Expires: Never"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Expires: \(formatter.string(from: Date(timeIntervalSince1970: TimeInterval(expiresAt))))"
    }

    private func trafficText(for client: ServerAdminClientInfo) -> String {
        let total = max(0, (client.downBytes ?? 0) + (client.upBytes ?? 0))
        return "Traffic: \(formatBytes(total))"
    }

    private var defaultPortsValue: String {
        isWDTTManagement ? "56000,56001,9000" : "46000,46001,0"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .binary
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
    }

    private func normalizedPortsInput(_ value: String) -> String {
        value
            .components(separatedBy: .newlines)
            .joined()
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: ",")
    }

    private func generateClientPassword(length: Int = 16) -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789")
        var bytes = [UInt8](repeating: 0, count: max(length, 12))
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            return String((0..<max(length, 12)).map { _ in
                alphabet.randomElement() ?? "A"
            })
        }
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }
}

private extension ISO8601DateFormatter {
    static let compactFileNameTimestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}

private struct ServerManagementActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
