import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import CoreImage.CIFilterBuiltins

struct ServerManagementView: View {
    let target: ServerAdminTarget?
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

    var body: some View {
        Form {
            Section(header: Text("Clients")) {
                HStack {
                    Button {
                        refreshServerClients()
                    } label: {
                        Label(isLoadingClients ? "Refreshing..." : "Refresh Clients", systemImage: "arrow.clockwise")
                    }
                    .disabled(!canManage || isLoadingClients)

                    Spacer()

                    Button {
                        showCreateClientSheet = true
                    } label: {
                        Label("New Client", systemImage: "plus")
                    }
                    .disabled(!canManage)
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

                            Text(expiryText(for: client))
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

            if canManage {
                Section(header: Text("Cleanup")) {
                    Button("Cleanup Expired") {
                        runGlobalAction(.cleanupExpired)
                    }
                    .disabled(!canManage)

                    Button("Cleanup Orphans") {
                        runGlobalAction(.cleanupOrphans)
                    }
                    .disabled(!canManage)

                    Button("Import Client") {
                        showImportPicker = true
                    }
                    .disabled(!canManage)
                }
            }

            if !canManage {
                Section {
                    Text("Fill in server host, SSH password, and WDTT main password in Deploy before opening management.")
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
                        Text(client.password)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        TextField("Label", text: $editedLabel)
                        TextField("VK Hash", text: $editedHash)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
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

                    Section(header: Text("Password")) {
                        TextField("New Password", text: $editedNewPassword)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
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
    }

    private var canManage: Bool {
        canConnect && target != nil
    }

    private func refreshServerClients() {
        guard let target, !isLoadingClients else { return }
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
        guard let target else { return }
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

    private func beginEditing(_ client: ServerAdminClientInfo) {
        editingClient = client
        editedLabel = client.label ?? ""
        editedHash = client.vkHash ?? ""
        editedPorts = client.ports ?? "56000,56001,9000"
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
        Task {
            do {
                _ = try await ServerAdminBridge.update(target, request: ServerAdminUpdateRequest(
                    clientPassword: client.password,
                    label: editedLabel,
                    vkHash: editedHash,
                    ports: editedPorts,
                    days: nil,
                    expiresAt: nil,
                    newPassword: ""
                ))

                _ = try await ServerAdminBridge.setExpiry(
                    target,
                    clientPassword: client.password,
                    days: editedNeverExpires ? nil : editedExpiryDays,
                    expiresAt: editedNeverExpires ? 0 : nil
                )

                if !trimmedPassword.isEmpty {
                    _ = try await ServerAdminBridge.setPassword(
                        target,
                        clientPassword: client.password,
                        newPassword: trimmedPassword
                    )
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

    private func runGlobalAction(_ action: ServerAdminAction) {
        guard let target else { return }
        Task {
            do {
                let response = try await ServerAdminBridge.run(action, target: target)
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
                _ = try await ServerAdminBridge.importClient(target, transferText: text)
                await MainActor.run {
                    resultTitle = "Import Complete"
                    resultMessage = "The client was imported."
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

    private func quickLink(for client: ServerAdminClientInfo) -> String? {
        guard let target, let rawHash = client.vkHash?.trimmingCharacters(in: .whitespacesAndNewlines), !rawHash.isEmpty else {
            return nil
        }
        let ports = (client.ports?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? client.ports! : "56000,56001,9000")
        let parts = ports.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 3 else { return nil }
        return "wdtt://\(target.host):\(parts[0]):\(parts[1]):\(parts[2]):\(client.password):\(rawHash)"
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
}

private struct ServerManagementActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
