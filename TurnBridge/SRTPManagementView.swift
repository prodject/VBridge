import SwiftUI
import UIKit

struct SRTPManagementView: View {
    let target: SRTPAdminTarget?
    let canConnect: Bool

    @State private var clients: [SRTPAdminClientInfo] = []
    @State private var loading = false
    @State private var showCreate = false
    @State private var label = ""
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showAlert = false
    @State private var shareItems: [Any] = []
    @AppStorage("deploy.srtp.shareVKLinks") private var shareVKLinks = ""

    var body: some View {
        Form {
            Section("Quick Link") {
                TextField("VK call URL or hash (optional)", text: $shareVKLinks, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("Leave empty to keep the receiving app's existing VK calls. If filled in, these calls replace its current list. Separate multiple calls by newlines.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Clients") {
                HStack {
                    Button(loading ? "Refreshing..." : "Refresh") { refresh() }
                        .disabled(!canManage || loading)
                    Spacer()
                    Button("New") { showCreate = true }
                        .disabled(!canManage || loading)
                }
                if clients.isEmpty {
                    Text(loading ? "Loading clients..." : "No SRTP clients.")
                        .foregroundColor(.secondary)
                }
                ForEach(clients) { client in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(client.label.isEmpty ? client.address : client.label).font(.headline)
                        Text("IP: \(client.address)").font(.caption).foregroundColor(.secondary)
                        Text(client.publicKey).font(.caption.monospaced()).foregroundColor(.secondary).lineLimit(1)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                Button("Copy Profile") { copyProfile(client) }.buttonStyle(.bordered)
                                Button("Quick Link") { shareQuickLink(client) }.buttonStyle(.bordered)
                                Button("Export") { exportProfile(client) }.buttonStyle(.bordered)
                                Button("Delete", role: .destructive) { delete(client) }.buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            if !canManage {
                Section { Text("Fill in server host and SSH credentials before opening management.").foregroundColor(.secondary) }
            }
        }
        .navigationTitle("SRTP Management")
        .navigationBarTitleDisplayMode(.inline)
        .task { refresh() }
        .sheet(isPresented: $showCreate) {
            NavigationStack {
                Form {
                    TextField("Client name", text: $label)
                    Button("Create Client") { create() }.disabled(loading)
                }
                .navigationTitle("New SRTP Client")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showCreate = false } } }
            }
        }
        .sheet(isPresented: Binding(get: { !shareItems.isEmpty }, set: { if !$0 { shareItems = [] } })) {
            if !shareItems.isEmpty { ServerManagementActivityView(items: shareItems) }
        }
        .alert(alertTitle, isPresented: $showAlert) { Button("OK", role: .cancel) {} } message: { Text(alertMessage) }
    }

    private var canManage: Bool { canConnect && target != nil }

    private func refresh() {
        guard let target, !loading else { return }
        loading = true
        Task {
            do {
                let value = try await SRTPAdminBridge.list(target)
                await MainActor.run { clients = value; loading = false }
            } catch { await MainActor.run { fail("Refresh Failed", error); loading = false } }
        }
    }

    private func create() {
        guard let target else { return }
        loading = true
        Task {
            do {
                let value = try await SRTPAdminBridge.create(target, label: label.trimmingCharacters(in: .whitespacesAndNewlines))
                await MainActor.run { clients = value; label = ""; loading = false; showCreate = false }
            } catch { await MainActor.run { fail("Create Failed", error); loading = false } }
        }
    }

    private func delete(_ client: SRTPAdminClientInfo) {
        guard let target else { return }
        loading = true
        Task {
            do {
                let value = try await SRTPAdminBridge.delete(target, id: client.id)
                await MainActor.run { clients = value; loading = false }
            } catch { await MainActor.run { fail("Delete Failed", error); loading = false } }
        }
    }

    private func copyProfile(_ client: SRTPAdminClientInfo) {
        guard let target else { return }
        do {
            UIPasteboard.general.string = try SRTPAdminBridge.profileLink(target, client: client)
            alertTitle = "Profile Copied"
            alertMessage = "Import the copied VBridge profile, then add a VK call URL or hash."
            showAlert = true
        } catch { fail("Copy Failed", error) }
    }

    private func shareQuickLink(_ client: SRTPAdminClientInfo) {
        guard let target else { return }
        do {
            shareItems = [try ExternalClientLinks.srtp(
                host: target.host, port: target.dtlsPort, config: client.config,
                calls: shareVKLinks, name: client.label.isEmpty ? "SRTP \(client.address)" : client.label
            )]
        } catch { fail("Share Failed", error) }
    }

    private func exportProfile(_ client: SRTPAdminClientInfo) {
        guard let target else { return }
        do {
            let text = try SRTPAdminBridge.profileLink(target, client: client)
            let safeName = client.label.replacingOccurrences(of: "/", with: "-")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName.isEmpty ? "srtp-client" : safeName).vbridge")
            try text.write(to: url, atomically: true, encoding: .utf8)
            shareItems = [url]
        } catch { fail("Export Failed", error) }
    }

    private func fail(_ title: String, _ error: Error) {
        alertTitle = title
        alertMessage = error.localizedDescription
        showAlert = true
    }
}
