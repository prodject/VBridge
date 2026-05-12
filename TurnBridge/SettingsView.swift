import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject var store: ProfileStore
    var profileID: UUID
    var isNewProfile: Bool = false

    @Environment(\.dismiss) private var dismiss
    @State private var draft: VPNProfile?
    @State private var showDeleteConfirmation = false
    @State private var showExportError = false
    @State private var exportErrorMessage = ""
    @State private var showQRScanner = false
    @State private var showScannerError = false
    @State private var scannerErrorMessage = ""
    @State private var showLinkGeneratedAlert = false

    private var profile: VPNProfile {
        draft ?? store.profiles.first(where: { $0.id == profileID }) ?? VPNProfile()
    }

    var body: some View {
        Form {
            Section(header: Text("Profile")) {
                TextField("Profile Name", text: binding(\.name))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }

            Section(header: Text("Proxy Settings")) {
                TextField("TURN Server URL", text: binding(\.vkLink))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)

                TextField("Peer Address (IP:Port)", text: binding(\.peerAddr))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)

                TextField("Listen Address (IP:Port)", text: binding(\.listenAddr))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)

                Stepper("Connections (n): \(profile.nValue)", value: binding(\.nValue), in: 1...32)
                Stepper("Workers per TURN identity: \(profile.credsGroupSize)", value: binding(\.credsGroupSize), in: 1...32)
                Text("`n` controls total parallel TURN sessions. `Workers per TURN identity` controls how many workers share the same VK/TURN credentials. The WINGSV-style stable default is 10 sessions with 12 workers per identity.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("WireGuard Config")) {
                TextEditor(text: binding(\.wgQuickConfig))
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 150)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }

            Section(header: Text("Advanced Proxy")) {
                Toggle(isOn: binding(\.useUdp)) {
                    VStack(alignment: .leading) {
                        Text("Use UDP")
                        Text("Prefer UDP for TURN transport. Disable this to force TCP.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                TextField("TURN Host Override", text: binding(\.turnHost))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)

                TextField("TURN Port Override", text: binding(\.turnPort))
                    .keyboardType(.numberPad)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)

                Text("Leave host and port empty to use the server suggested by the invite link.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("Transfer")) {
                Button(action: generateQuickImportLink) {
                    HStack {
                        Spacer()
                        Label("Generate Link", systemImage: "link.badge.plus")
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }

            Section {
                Button(role: .destructive, action: {
                    showDeleteConfirmation = true
                }) {
                    HStack {
                        Spacer()
                        Text("Delete Profile")
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle(isNewProfile ? "New Profile" : "Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button(action: { showQRScanner = true }) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.title3)
                        .foregroundColor(.primary)
                }

                Button(action: { dismiss() }) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.primary)
                }
            }
        }
        .onAppear {
            if draft == nil {
                draft = store.profiles.first(where: { $0.id == profileID })
            }
        }
        .alert("Delete Profile?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                store.deleteProfile(profileID)
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Profile \"\(profile.name)\" will be permanently deleted.")
        }
        .alert("Export Error", isPresented: $showExportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportErrorMessage)
        }
        .alert("Scanner Error", isPresented: $showScannerError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(scannerErrorMessage)
        }
        .alert("Link Copied", isPresented: $showLinkGeneratedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("vbridge link copied to clipboard.")
        }
        .sheet(isPresented: $showQRScanner) {
            WireGuardQRScannerView(
                onCode: { code in
                    showQRScanner = false
                    applyScannedWireGuardConfig(code)
                },
                onError: { message in
                    showQRScanner = false
                    scannerErrorMessage = message
                    showScannerError = true
                }
            )
            .ignoresSafeArea()
        }
        .onDisappear {
            guard let draft else { return }
            if store.profiles.contains(where: { $0.id == profileID }) {
                store.selectedProfile = draft
            }
        }
    }

    private func applyScannedWireGuardConfig(_ raw: String) {
        let normalized = normalizeScannedText(raw)
        binding(\.wgQuickConfig).wrappedValue = normalized
    }

    private func normalizeScannedText(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let decoded = decodeAmneziaScannedText(trimmed) {
            return decoded
        }
        if trimmed.contains("\\n") && !trimmed.contains("\n") {
            return trimmed.replacingOccurrences(of: "\\n", with: "\n")
        }
        return trimmed
    }

    private func decodeAmneziaScannedText(_ input: String) -> String? {
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if normalized.contains("[Interface]") || normalized.contains("[Peer]") {
            return nil
        }

        guard let data = Data(base64Encoded: normalized, options: [.ignoreUnknownCharacters])
                ?? Data(base64Encoded: normalized.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"), options: [.ignoreUnknownCharacters]),
              let decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            return nil
        }

        let candidates = [decoded, normalized]
        for candidate in candidates {
            if let range = candidate.range(of: "[Interface]") {
                let config = String(candidate[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if config.contains("[Peer]") {
                    return config
                }
            }
        }
        return nil
    }

    private func generateQuickImportLink() {
        let payload: [String: Any] = [
            "name": profile.name,
            "turn": profile.vkLink,
            "peer": profile.peerAddr,
            "listen": profile.listenAddr,
            "n": profile.nValue,
            "credsGroupSize": profile.credsGroupSize,
            "wg": profile.wgQuickConfig,
            "turnHost": profile.turnHost,
            "turnPort": profile.turnPort,
            "udp": profile.useUdp
        ]

        guard JSONSerialization.isValidJSONObject(payload),
              let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: jsonData, encoding: .utf8) else {
            exportErrorMessage = "Failed to generate quick link."
            showExportError = true
            return
        }

        let base64 = Data(json.utf8).base64EncodedString()
        let link = "vbridge://\(base64)"
        UIPasteboard.general.string = link
        showLinkGeneratedAlert = true
    }

    private func binding<T>(_ keyPath: WritableKeyPath<VPNProfile, T>) -> Binding<T> {
        Binding(
            get: { profile[keyPath: keyPath] },
            set: { newValue in
                if draft == nil {
                    draft = store.profiles.first(where: { $0.id == profileID })
                }
                draft?[keyPath: keyPath] = newValue
            }
        )
    }
}
