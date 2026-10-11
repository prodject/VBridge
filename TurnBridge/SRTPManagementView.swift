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
    @State private var showVKCallCreator = false
    @State private var pendingProfileClient: SRTPAdminClientInfo?
    @State private var pendingProfileExport = false

    var body: some View {
        Form {
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
        .sheet(isPresented: $showVKCallCreator) {
            VKCallURLCreatorView(
                onSuccess: { turnURL in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        completeProfileDelivery(turnURL: turnURL)
                    }
                },
                onCancel: { clearPendingProfileDelivery() },
                onNeedsLogin: {
                    clearPendingProfileDelivery()
                    fail("VK Authorization Required", NSError(
                        domain: "SRTPManagementView",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Saved VK session is missing or expired. Run VK Authorization in Settings -> Extended Features."]
                    ))
                }
            )
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
        beginProfileDelivery(client, export: false)
    }

    private func exportProfile(_ client: SRTPAdminClientInfo) {
        beginProfileDelivery(client, export: true)
    }

    private func beginProfileDelivery(_ client: SRTPAdminClientInfo, export: Bool) {
        guard target != nil else { return }
        guard VKCookieStore.isValid() else {
            fail("VK Authorization Required", NSError(
                domain: "SRTPManagementView",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Authorize VK in Settings -> Extended Features before copying or exporting an SRTP profile."]
            ))
            return
        }
        pendingProfileClient = client
        pendingProfileExport = export
        showVKCallCreator = true
    }

    private func completeProfileDelivery(turnURL: String) {
        defer { clearPendingProfileDelivery() }
        let trimmedURL = turnURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty, let target, let client = pendingProfileClient else {
            fail("Profile Export Failed", NSError(
                domain: "SRTPManagementView",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "VK returned an empty TURN call URL."]
            ))
            return
        }
        do {
            let text = try SRTPAdminBridge.profileLink(target, client: client, turnURL: trimmedURL)
            if pendingProfileExport {
                let safeName = client.label.replacingOccurrences(of: "/", with: "-")
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName.isEmpty ? "srtp-client" : safeName).vbridge")
                try text.write(to: url, atomically: true, encoding: .utf8)
                shareItems = [url]
            } else {
                UIPasteboard.general.string = text
                alertTitle = "Profile Copied"
                alertMessage = "The SRTP profile includes its TURN call URL and is ready to import."
                showAlert = true
            }
        } catch { fail(pendingProfileExport ? "Export Failed" : "Copy Failed", error) }
    }

    private func clearPendingProfileDelivery() {
        pendingProfileClient = nil
        pendingProfileExport = false
    }

    private func fail(_ title: String, _ error: Error) {
        alertTitle = title
        alertMessage = error.localizedDescription
        showAlert = true
    }
}
