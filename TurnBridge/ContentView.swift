import SwiftUI
import NetworkExtension
import UniformTypeIdentifiers

struct SettingsSheet: Identifiable {
    let id = UUID()
    let profileID: UUID
    let isNew: Bool
}

struct ContentView: View {
    var app: VBridge

    @AppStorage("autoUpdateEnabled") private var autoUpdateEnabled = true
    @AppStorage("tetherProxyEnabled") private var tetherProxyEnabled = false
    @AppStorage("tetherProxyPort") private var tetherProxyPort = 9000

    @State private var vpnStatus: NEVPNStatus = .disconnected
    @StateObject private var store = ProfileStore()

    @State private var showImportModal = false
    @State private var showingAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var connectWatchdogTask: Task<Void, Never>?
    @State private var settingsSheet: SettingsSheet?
    @StateObject private var captchaBridge = CaptchaBridge()
    @State private var didCheckForUpdates = false
    @State private var isDownloadingUpdate = false
    @State private var isCheckingUpdate = false
    @State private var showProfileImporter = false

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color.blue.opacity(0.18),
                        Color.cyan.opacity(0.08),
                        Color.mint.opacity(0.08)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: 20) {
                    VStack(spacing: 4) {
                        Text("VBridge")
                            .font(.system(size: 44, weight: .black, design: .rounded))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.blue, .cyan, .mint],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .shadow(color: .blue.opacity(0.25), radius: 10, x: 0, y: 5)

                        Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)

                    if !store.profiles.isEmpty {
                        profilePicker
                            .disabled(vpnStatus != .disconnected)
                            .padding(16)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(Color.white.opacity(0.25), lineWidth: 1)
                            )
                            .padding(.horizontal, 20)
                    }

                    Spacer(minLength: 0)

                    VStack(spacing: 22) {
                        Image(systemName: vpnStatus == .connected ? "lock.shield.fill" : "lock.shield")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 112, height: 112)
                            .foregroundColor(iconColor)
                            .shadow(color: iconColor.opacity(0.4), radius: vpnStatus == .connected ? 20 : 0)
                            .scaleEffect(vpnStatus == .connecting ? 1.08 : 1.0)
                            .animation(vpnStatus == .connecting ? .easeInOut(duration: 1).repeatForever() : .default, value: vpnStatus)

                        Button(action: {
                            Task { await checkForUpdates(manual: true) }
                        }) {
                            HStack(spacing: 8) {
                                if isCheckingUpdate || isDownloadingUpdate {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .tint(.blue)
                                        .scaleEffect(0.8)
                                }
                                Text(isDownloadingUpdate ? "Downloading update..." : (isCheckingUpdate ? "Checking..." : "Check update"))
                                    .font(.subheadline.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.blue.opacity(0.12))
                            .foregroundColor(.blue)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .disabled(isCheckingUpdate || isDownloadingUpdate)

                        Button(action: toggleTunnel) {
                            Text(buttonText)
                                .font(.title3.weight(.bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(buttonColor)
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .shadow(color: buttonColor.opacity(0.35), radius: 8, x: 0, y: 5)
                        }
                        .disabled(isConnectButtonDisabled)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .stroke(Color.white.opacity(0.25), lineWidth: 1)
                    )
                    .padding(.horizontal, 20)

                    Spacer()
                }
            }
            .overlay {
                if showImportModal {
                    importModalView
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        if vpnStatus == .disconnected {
                            withAnimation { showImportModal = true }
                        }
                    }) {
                        Image(systemName: "plus")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(vpnStatus == .disconnected ? .primary : .secondary)
                    }
                }

                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button(action: {
                        guard let id = store.selectedProfileID else { return }
                        if vpnStatus == .disconnected {
                            settingsSheet = SettingsSheet(profileID: id, isNew: false)
                        }
                    }) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.title3)
                            .foregroundColor(vpnStatus == .disconnected && store.selectedProfile != nil ? .primary : .secondary)
                    }

                    NavigationLink(destination: GlobalSettingsView()) {
                        Image(systemName: "gearshape.fill")
                            .font(.title3)
                            .foregroundColor(.primary)
                    }
                }
            }
            .sheet(item: $settingsSheet) { sheet in
                NavigationStack {
                    SettingsView(store: store, profileID: sheet.profileID, isNewProfile: sheet.isNew)
                }
            }
            .sheet(item: $captchaBridge.activeRequest, onDismiss: {
                captchaBridge.clear()
            }) { request in
                CaptchaSolverView(request: request) {
                    captchaBridge.clear()
                }
            }
            .onAppear(perform: checkInitialStatus)
            .onAppear {
                if !didCheckForUpdates {
                    didCheckForUpdates = true
                    Task { await checkForUpdates(manual: false) }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NEVPNStatusDidChange)) { notification in
                if let connection = notification.object as? NEVPNConnection {
                    let newStatus = connection.status
                    let statusName: String = {
                        switch newStatus {
                        case .connected:     return "Connected"
                        case .connecting:    return "Connecting"
                        case .disconnected:  return "Disconnected"
                        case .disconnecting: return "Disconnecting"
                        case .reasserting:   return "Reasserting"
                        case .invalid:       return "Invalid"
                        @unknown default:    return "Unknown"
                        }
                    }()
                    SharedLogger.info("VPN status: \(statusName)")
                    withAnimation { self.vpnStatus = newStatus }
                    if newStatus != .connecting {
                        cancelConnectWatchdog()
                    }
                }
            }
            .alert(alertTitle, isPresented: $showingAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(alertMessage)
            }
            .fileImporter(
                isPresented: $showProfileImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    importProfile(from: url)
                case .failure(let error):
                    showAlert(title: "Import Error", message: error.localizedDescription)
                }
            }
        }
    }
    
    private var profilePicker: some View {
        Menu {
            ForEach(store.profiles) { profile in
                Button(action: {
                    store.selectedProfileID = profile.id
                    store.save()
                }) {
                    if profile.id == store.selectedProfileID {
                        Label(profile.name, systemImage: "checkmark")
                    } else {
                        Text(profile.name)
                    }
                }
            }
        } label: {
            HStack {
                Text(store.selectedProfile?.name ?? "Select Profile")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1)
            )
        }
    }

    private var importModalView: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation { showImportModal = false }
                }

            VStack(spacing: 16) {
                Text("Add Configuration")
                    .font(.headline)

                Button(action: importFromClipboard) {
                    HStack {
                        Image(systemName: "doc.on.clipboard")
                        Text("Paste from Clipboard")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }

                Button(action: {
                    withAnimation { showImportModal = false }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        showProfileImporter = true
                    }
                }) {
                    HStack {
                        Image(systemName: "tray.and.arrow.down")
                        Text("Import Profile")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.indigo)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }

                Button(action: addManualProfile) {
                    HStack {
                        Image(systemName: "square.and.pencil")
                        Text("Add Manually")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }

                Button(action: {
                    withAnimation { showImportModal = false }
                }) {
                    Text("Cancel")
                        .fontWeight(.medium)
                        .foregroundColor(.gray)
                }
            }
            .padding(24)
            .frame(width: 300)
            .background(.regularMaterial)
            .cornerRadius(24)
            .shadow(color: .black.opacity(0.15), radius: 20, x: 0, y: 10)
            .transition(.scale(scale: 0.95).combined(with: .opacity))
        }
    }

    private var buttonText: String {
        switch vpnStatus {
        case .connected: return "Disconnect"
        case .connecting, .reasserting: return "Stop"
        case .disconnecting: return "Stopping..."
        default: return "Connect"
        }
    }

    private var buttonColor: Color {
        switch vpnStatus {
        case .connected: return .red
        case .connecting, .disconnecting: return .orange
        default: return .blue
        }
    }

    private var isConnectButtonDisabled: Bool {
        switch vpnStatus {
        case .disconnecting:
            return true
        case .disconnected, .invalid:
            return store.selectedProfile == nil
        default:
            return false
        }
    }

    private var iconColor: Color {
        switch vpnStatus {
        case .connected: return .green
        case .connecting, .disconnecting: return .orange
        default: return .gray
        }
    }

    private func validateConfig(_ profile: VPNProfile) -> String? {
        if profile.vkLink.isEmpty {
            return "Please provide a valid TURN Server URL."
        }
        if profile.peerAddr.isEmpty {
            return "Please provide a valid Peer Address."
        }
        if profile.listenAddr.isEmpty {
            return "Please provide a valid Listen Address."
        }
        if profile.wgQuickConfig.isEmpty {
            return "Please provide a valid WireGuard configuration."
        }
        return nil
    }

    private func toggleTunnel() {
        if vpnStatus == .connected || vpnStatus == .connecting || vpnStatus == .reasserting {
            SharedLogger.info("User requested stop (status: \(vpnStatus.rawValue))")
            cancelConnectWatchdog()
            app.turnOffTunnel()
            vpnStatus = .disconnecting
        } else {
            guard let profile = store.selectedProfile else { return }
            if let errorMessage = validateConfig(profile) {
                SharedLogger.warning("Config validation failed: \(errorMessage)")
                showAlert(title: "Configuration Required", message: errorMessage)
                return
            }

            SharedLogger.info("User requested connect with profile \"\(profile.name)\"")
            vpnStatus = .connecting
            let effectiveListenAddr = resolvedListenAddress(from: profile.listenAddr)
            tetherProxyPort = extractPort(from: effectiveListenAddr) ?? 9000
            SharedLogger.info("Proxy listen mode: \(tetherProxyEnabled ? "tether" : "local"), addr=\(effectiveListenAddr)")
            app.turnOnTunnel(
                vkLink: profile.vkLink,
                peerAddr: profile.peerAddr,
                listenAddr: effectiveListenAddr,
                nValue: profile.nValue,
                wgQuickConfig: profile.wgQuickConfig
            ) { isSuccess in
                if !isSuccess {
                    cancelConnectWatchdog()
                    vpnStatus = .disconnected
                    SharedLogger.error("Tunnel start failed")
                }
            }
            startConnectWatchdog()
        }
    }

    private func checkInitialStatus() {
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let manager = managers?.first {
                self.vpnStatus = manager.connection.status
            } else {
                self.vpnStatus = .disconnected
            }
        }
    }

    private func importFromClipboard() {
        guard let clipboardString = UIPasteboard.general.string else {
            SharedLogger.warning("Clipboard import failed: clipboard is empty")
            withAnimation { showImportModal = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                showAlert(title: "Error", message: "Clipboard is empty.")
            }
            return
        }

        SharedLogger.debug("Parsing clipboard config (\(clipboardString.count) chars)")
        do {
            let config = try ConfigParser.parse(from: clipboardString)
            let profile = VPNProfile(
                name: config.name ?? "Profile",
                vkLink: config.turn,
                peerAddr: config.peer,
                listenAddr: config.listen,
                nValue: config.n,
                wgQuickConfig: config.wg
            )
            store.addProfile(profile)
            SharedLogger.info("Profile \"\(store.selectedProfile?.name ?? "")\" imported from clipboard")

            withAnimation { showImportModal = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                showAlert(title: "Success", message: "Profile \"\(store.selectedProfile?.name ?? "")\" imported.")
            }
        } catch {
            SharedLogger.error("Clipboard import failed: \(error.localizedDescription)")
            withAnimation { showImportModal = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                showAlert(title: "Error", message: error.localizedDescription)
            }
        }
    }

    private func addManualProfile() {
        withAnimation { showImportModal = false }
        let profile = VPNProfile(name: "Profile")
        store.addProfile(profile)
        SharedLogger.info("New manual profile created: \"\(store.selectedProfile?.name ?? "")\"")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            settingsSheet = SettingsSheet(profileID: profile.id, isNew: true)
        }
    }

    private func importProfile(from url: URL) {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let ext = url.pathExtension.lowercased()
            guard ext.isEmpty || ext == "vbridge" || ext == "json" else {
                showAlert(title: "Import Error", message: "Unsupported file type: .\(ext)")
                return
            }

            let data = try Data(contentsOf: url)
            let package = try VBridgeProfilePackage.decode(from: data)
            let imported = package.profile
            let profile = VPNProfile(
                id: UUID(),
                name: imported.name,
                vkLink: imported.vkLink,
                peerAddr: imported.peerAddr,
                listenAddr: imported.listenAddr,
                nValue: imported.nValue,
                wgQuickConfig: imported.wgQuickConfig
            )
            store.addProfile(profile)
            package.appSettings.apply()
            showAlert(title: "Imported", message: "Profile \"\(profile.name)\" imported from .vbridge")
        } catch {
            showAlert(title: "Import Error", message: error.localizedDescription)
        }
    }

    private func showAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showingAlert = true
    }

    private func startConnectWatchdog() {
        cancelConnectWatchdog()
        connectWatchdogTask = Task {
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard vpnStatus == .connecting else { return }

                SharedLogger.error("Connection timeout while waiting for tunnel readiness")
                app.turnOffTunnel()
                vpnStatus = .disconnected
                showAlert(
                    title: "Connection Timeout",
                    message: "Tunnel startup timed out (45s). Check Logs and Captcha flow, then try again."
                )
            }
        }
    }

    private func cancelConnectWatchdog() {
        connectWatchdogTask?.cancel()
        connectWatchdogTask = nil
    }

    private func resolvedListenAddress(from original: String) -> String {
        guard tetherProxyEnabled else { return original }
        let port = extractPort(from: original) ?? 9000
        return "0.0.0.0:\(port)"
    }

    private func extractPort(from listenAddress: String) -> Int? {
        let trimmed = listenAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = trimmed.lastIndex(of: ":") else { return nil }
        let portPart = trimmed[trimmed.index(after: index)...]
        return Int(portPart)
    }

    private func checkForUpdates(manual: Bool) async {
        if !manual {
            guard autoUpdateEnabled else { return }
        }
        guard !isDownloadingUpdate else { return }
        guard !isCheckingUpdate else { return }

        await MainActor.run { isCheckingUpdate = true }
        defer { Task { @MainActor in isCheckingUpdate = false } }

        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        if let info = await UpdateChecker.checkForUpdate(currentVersion: currentVersion) {
            SharedLogger.info("[Update] New version available: \(info.latestVersion)")
            await downloadUpdate(info)
        } else {
            SharedLogger.debug("[Update] No update available")
            if manual {
                await MainActor.run {
                    showAlert(title: "No Updates", message: "You already have the latest version.")
                }
            }
        }
    }

    @MainActor
    private func downloadUpdate(_ info: UpdateInfo) async {
        guard !isDownloadingUpdate else { return }
        isDownloadingUpdate = true
        defer { isDownloadingUpdate = false }

        SharedLogger.info("[Update] Downloading IPA: \(info.ipaURL.absoluteString)")
        do {
            let (temporaryURL, response) = try await URLSession.shared.download(from: info.ipaURL)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                showAlert(title: "Update Error", message: "Failed to download update IPA.")
                return
            }

            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let fileName = info.ipaFileName.isEmpty ? "VBridge-\(info.latestVersion).ipa" : info.ipaFileName
            let destination = docs.appendingPathComponent(fileName)

            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: destination)

            SharedLogger.info("[Update] IPA saved to: \(destination.path)")
            showAlert(
                title: "Update Downloaded",
                message: "IPA downloaded to Files: \(fileName)"
            )
        } catch {
            SharedLogger.error("[Update] IPA download failed: \(error.localizedDescription)")
            showAlert(title: "Update Error", message: "Download failed: \(error.localizedDescription)")
        }
    }
}
