import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject var store: ProfileStore
    var profileID: UUID
    var isNewProfile: Bool = false

    @Environment(\.dismiss) private var dismiss
    @State private var draft: VPNProfile?
    @State private var showDeleteConfirmation = false
    @State private var exportDocument = VBridgeProfileDocument(package: VBridgeProfilePackage.fromCurrent(profile: VPNProfile(name: "Profile")))
    @State private var showExporter = false
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

                Stepper("Connections (n): \(profile.nValue)", value: binding(\.nValue), in: 1...16)
            }

            Section(header: Text("WireGuard Config")) {
                TextEditor(text: binding(\.wgQuickConfig))
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 150)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
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
                .padding(.bottom, 8)

                Button(action: exportProfile) {
                    HStack {
                        Spacer()
                        Label("Export Profile", systemImage: "square.and.arrow.up")
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
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .vbridgeProfile,
            defaultFilename: "\(profile.name.replacingOccurrences(of: " ", with: "_")).vbridge"
        ) { result in
            if case .failure(let error) = result {
                exportErrorMessage = error.localizedDescription
                showExportError = true
            }
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

    private func exportProfile() {
        let package = VBridgeProfilePackage.fromCurrent(profile: profile)
        exportDocument = VBridgeProfileDocument(package: package)
        showExporter = true
    }

    private func applyScannedWireGuardConfig(_ raw: String) {
        let normalized = normalizeScannedText(raw)
        binding(\.wgQuickConfig).wrappedValue = normalized
    }

    private func normalizeScannedText(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("\\n") && !trimmed.contains("\n") {
            return trimmed.replacingOccurrences(of: "\\n", with: "\n")
        }
        return trimmed
    }

    private func generateQuickImportLink() {
        let payload: [String: Any] = [
            "name": profile.name,
            "turn": profile.vkLink,
            "peer": profile.peerAddr,
            "listen": profile.listenAddr,
            "n": profile.nValue,
            "wg": profile.wgQuickConfig
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
