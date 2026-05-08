import SwiftUI
import NetworkExtension
import UniformTypeIdentifiers
#if canImport(WidgetKit)
import WidgetKit
#endif

struct SettingsSheet: Identifiable {
    let id = UUID()
    let profileID: UUID
    let isNew: Bool
}

private struct ConnectionPingSample: Equatable {
    let name: String
    let latencyMs: Int?

    init(shared sample: VBridgePingSample) {
        self.name = sample.name
        self.latencyMs = sample.latencyMs
    }

    var dotColor: Color {
        guard let latencyMs else { return .gray.opacity(0.45) }
        switch latencyMs {
        case ..<30:
            return .green
        case ..<60:
            return .mint
        case ..<100:
            return .yellow
        case ..<150:
            return .orange
        default:
            return .red
        }
    }

    var dotCount: Int {
        guard let latencyMs else { return 0 }
        switch latencyMs {
        case ..<30:
            return 5
        case ..<60:
            return 4
        case ..<100:
            return 3
        case ..<150:
            return 2
        default:
            return 1
        }
    }

    var compactLatencyText: String {
        guard let latencyMs else { return "--" }
        return "\(latencyMs)ms"
    }

    var badgeText: String {
        switch name {
        case "Cloudflare":
            return "CF"
        case "Google":
            return "GO"
        case "Yandex":
            return "YN"
        default:
            return String(name.prefix(2)).uppercased()
        }
    }

    var sharedRepresentation: VBridgePingSample {
        VBridgePingSample(name: name, latencyMs: latencyMs)
    }

    static let targets: [(String, URL)] = [
        ("Cloudflare", URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!),
        ("Google", URL(string: "https://www.google.com/generate_204")!),
        ("Yandex", URL(string: "https://ya.ru")!)
    ]

    static let placeholderSamples: [ConnectionPingSample] = [
        ConnectionPingSample(name: "Cloudflare", latencyMs: 24),
        ConnectionPingSample(name: "Google", latencyMs: 41),
        ConnectionPingSample(name: "Yandex", latencyMs: 69)
    ]

    static func loadAll() async -> [ConnectionPingSample] {
        async let cloudflare = pingLatency(for: targets[0].1)
        async let google = pingLatency(for: targets[1].1)
        async let yandex = pingLatency(for: targets[2].1)

        return [
            ConnectionPingSample(name: targets[0].0, latencyMs: await cloudflare),
            ConnectionPingSample(name: targets[1].0, latencyMs: await google),
            ConnectionPingSample(name: targets[2].0, latencyMs: await yandex)
        ]
    }

    private static func pingLatency(for url: URL) async -> Int? {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 3
        let session = URLSession(configuration: config)

        let start = DispatchTime.now()
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...399).contains(http.statusCode) else {
                return nil
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            return Int(elapsed / 1_000_000)
        } catch {
            return nil
        }
    }
}

struct ContentView: View {
    var app: VBridge

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("autoUpdateEnabled") private var autoUpdateEnabled = true
    @AppStorage("tetherProxyEnabled") private var tetherProxyEnabled = false
    @AppStorage("tetherProxyPort") private var tetherProxyPort = 9000
    @State private var vpnStatus: NEVPNStatus = .disconnected
    @StateObject private var store = ProfileStore()

    @State private var showImportModal = false
    @State private var showFileImporter = false
    @State private var showingAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var connectWatchdogTask: Task<Void, Never>?
    @State private var settingsSheet: SettingsSheet?
    @StateObject private var captchaBridge = CaptchaBridge()
    @State private var didCheckForUpdates = false
    @State private var isDownloadingUpdate = false
    @State private var isCheckingUpdate = false
    @State private var isUserInitiatedDisconnect = false
    @State private var hasLoadedInitialStatus = false
    @State private var connectionProgressText: String?
    @State private var downloadSpeedMbps: Double?
    @State private var uploadSpeedMbps: Double?
    @State private var connectionStartedAt: Date?
    @State private var lastWidgetRefreshSignature = ""
    @State private var logMonitoringTask: Task<Void, Never>?
    @State private var speedTestTask: Task<Void, Never>?
    @State private var lastSpeedMeasurementActiveConnections: Int?
    @State private var currentConnectivityPings: [ConnectionPingSample] = ConnectionPingSample.placeholderSamples
    @State private var pendingShortcutActionTask: Task<Void, Never>?

    private let connectWatchdogTimeout: UInt64 = 180
    private static let amneziaConfType = UTType(filenameExtension: "conf", conformingTo: .data)
    private static let vbridgeType = UTType(filenameExtension: "vbridge", conformingTo: .data)
    private static let importFileTypes: [UTType] = [
        Self.amneziaConfType,
        Self.vbridgeType
    ].compactMap { $0 }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.94, green: 0.93, blue: 0.97).opacity(0.96),
                        Color(red: 0.86, green: 0.82, blue: 0.96).opacity(0.92),
                        Color(red: 0.66, green: 0.54, blue: 0.97).opacity(0.86)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: 20) {
                    VStack(spacing: 4) {
                        Text("VBridge")
                            .font(.system(size: 44, weight: .bold, design: .default))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.32, green: 0.30, blue: 0.40),
                                        Color(red: 0.53, green: 0.37, blue: 0.98),
                                        Color(red: 0.40, green: 0.48, blue: 0.96)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .shadow(color: Color(red: 0.53, green: 0.37, blue: 0.98).opacity(0.22), radius: 10, x: 0, y: 5)

                        Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                            .font(.system(size: 14, weight: .semibold, design: .default))
                            .foregroundColor(.secondary)

                        connectionTelemetrySection
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 10)
                    .padding(.top, 16)

                    if !store.profiles.isEmpty {
                        profilePicker
                            .disabled(vpnStatus != .disconnected)
                            .padding(16)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(Color(red: 0.53, green: 0.37, blue: 0.98).opacity(0.16), lineWidth: 1)
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
                                        .tint(Color(red: 0.53, green: 0.37, blue: 0.98))
                                        .scaleEffect(0.8)
                                }
                                Text(isDownloadingUpdate ? "Downloading update..." : (isCheckingUpdate ? "Checking..." : "Check update"))
                                    .font(.system(size: 15, weight: .semibold, design: .default))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(updateButtonBackground)
                            .foregroundColor(updateButtonForeground)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(updateButtonBorder, lineWidth: 1)
                            )
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
            .sheet(isPresented: $showFileImporter) {
                DocumentPicker(
                    contentTypes: Self.importFileTypes,
                    onPick: { url in
                        showFileImporter = false
                        importFromFile(url)
                    },
                    onCancel: {
                        showFileImporter = false
                    }
                )
                .ignoresSafeArea()
            }
            .onOpenURL { url in
                if handleWidgetURL(url) {
                    return
                }
                guard url.isFileURL else { return }
                importFromFile(url)
            }
            .onAppear(perform: checkInitialStatus)
            .onAppear {
                if !didCheckForUpdates {
                    didCheckForUpdates = true
                    Task { await checkForUpdates(manual: false) }
                }
                lastWidgetRefreshSignature = widgetRefreshSignature()
                startLogMonitoring()
                refreshConnectionProgress()
                schedulePendingShortcutActionConsumption()
            }
            .onChange(of: scenePhase) { newPhase in
                if newPhase == .active {
                    schedulePendingShortcutActionConsumption()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .pendingShortcutActionDidChange)) { _ in
                schedulePendingShortcutActionConsumption()
            }
            .onDisappear {
                stopLogMonitoring()
                pendingShortcutActionTask?.cancel()
                pendingShortcutActionTask = nil
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
                    refreshConnectionProgress()
                    syncLiveActivityState(for: newStatus)
                    refreshWidgetTimelines()
                    if newStatus == .connected {
                        isUserInitiatedDisconnect = false
                        UserNotificationDispatcher.shared.clearConnectionIssueNotification()
                    } else if newStatus == .disconnected, isUserInitiatedDisconnect {
                        isUserInitiatedDisconnect = false
                        UserNotificationDispatcher.shared.clearConnectionIssueNotification()
                        endLiveActivity(immediate: true)
                    }
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
                    .background(Color(red: 0.53, green: 0.37, blue: 0.98))
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }

                Button(action: importFromFilePicker) {
                    HStack {
                        Image(systemName: "doc.badge.plus")
                        Text("Import from File")
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
        default: return Color(red: 0.53, green: 0.37, blue: 0.98)
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
        default: return Color(red: 0.53, green: 0.37, blue: 0.98)
        }
    }

    private var updateButtonBackground: Color {
        if colorScheme == .dark {
            return Color(red: 0.31, green: 0.20, blue: 0.68).opacity(0.92)
        }
        return Color(red: 0.53, green: 0.37, blue: 0.98).opacity(0.14)
    }

    private var updateButtonForeground: Color {
        colorScheme == .dark ? .white : Color(red: 0.53, green: 0.37, blue: 0.98)
    }

    private var updateButtonBorder: Color {
        colorScheme == .dark
            ? .white.opacity(0.14)
            : Color(red: 0.53, green: 0.37, blue: 0.98).opacity(0.18)
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
            isUserInitiatedDisconnect = true
            cancelConnectWatchdog()
            resetSpeedTelemetry()
            UserNotificationDispatcher.shared.clearConnectionIssueNotification()
            let currentProgress = latestConnectionProgressFromLogs()
            syncLiveActivityState(
                profileName: store.selectedProfile?.name ?? "VBridge",
                phase: .disconnecting,
                activeConnections: currentProgress?.active,
                totalConnections: currentProgress?.total,
                relayIP: latestRelayIPFromLogs()
            )
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
            isUserInitiatedDisconnect = false
            UserNotificationDispatcher.shared.clearConnectionIssueNotification()
            resetSpeedTelemetry()
            let configuredThreadCount = max(profile.nValue, 1)
            vpnStatus = .connecting
            connectionStartedAt = Date()
            refreshConnectionProgress()
            beginLiveActivity(for: profile, targetWorkers: configuredThreadCount)
            let effectiveListenAddr = resolvedListenAddress(from: profile.listenAddr)
            tetherProxyPort = extractPort(from: effectiveListenAddr) ?? 9000
            SharedLogger.info("Proxy listen mode: \(tetherProxyEnabled ? "tether" : "local"), addr=\(effectiveListenAddr)")
            app.turnOnTunnel(
                vkLink: profile.vkLink,
                peerAddr: profile.peerAddr,
                listenAddr: effectiveListenAddr,
                nValue: configuredThreadCount,
                wgQuickConfig: profile.wgQuickConfig,
                turnHost: profile.turnHost,
                turnPort: profile.turnPort,
                useUdp: profile.useUdp
            ) { isSuccess in
                if !isSuccess {
                    cancelConnectWatchdog()
                    resetSpeedTelemetry()
                    vpnStatus = .disconnected
                    SharedLogger.error("Tunnel start failed")
                    endLiveActivity(profileName: profile.name, immediate: true)
                    presentConnectionIssue(
                        title: "Connection Failed",
                        message: "Unable to start the tunnel. Check Logs and the captcha flow, then try again."
                    )
                }
                refreshWidgetTimelines()
            }
            startConnectWatchdog()
        }
    }

    private func checkInitialStatus() {
        NETunnelProviderManager.loadAllFromPreferences { managers, _ in
            DispatchQueue.main.async {
                let currentStatus = managers?.first?.connection.status ?? .disconnected
                let selectedProfileName = self.store.selectedProfile?.name ?? "VBridge"
                self.vpnStatus = currentStatus
                if currentStatus == .connected, let snapshot = VBridgeLiveActivityStore.load() {
                    self.downloadSpeedMbps = snapshot.content.downloadSpeedMbps
                    self.uploadSpeedMbps = snapshot.content.uploadSpeedMbps
                    if let pingSamples = snapshot.content.pingSamples {
                        self.currentConnectivityPings = pingSamples.map(ConnectionPingSample.init(shared:))
                    }
                }
                self.syncLiveActivityState(
                    profileName: selectedProfileName,
                    phase: self.liveActivityPhase(for: currentStatus)
                )
                self.hasLoadedInitialStatus = true
                self.refreshConnectionProgress()
                self.refreshWidgetTimelines()
                self.lastWidgetRefreshSignature = self.widgetRefreshSignature()
                self.schedulePendingShortcutActionConsumption()
            }
        }
    }

    private func startLogMonitoring() {
        stopLogMonitoring()
        logMonitoringTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 300_000_000)
                    await MainActor.run {
                        let signature = widgetRefreshSignature()
                        if signature != lastWidgetRefreshSignature {
                            lastWidgetRefreshSignature = signature
                            refreshWidgetTimelines()
                        }
                        refreshConnectionProgress()
                    }
                } catch {
                    break
                }
            }
        }
    }

    private func stopLogMonitoring() {
        logMonitoringTask?.cancel()
        logMonitoringTask = nil
    }

    private func refreshConnectionProgress() {
        let profile = store.selectedProfile
        let profileName = profile?.name ?? "VBridge"
        let target = profile.map(effectiveConnectionTarget(for:))

        guard vpnStatus == .connecting || vpnStatus == .connected || vpnStatus == .reasserting else {
            if let target {
                let fallbackProgress = vpnStatus == .connected ? target : 0
                connectionProgressText = "\(fallbackProgress)/\(target)"
                let remaining = estimatedRemainingSeconds(activeConnections: fallbackProgress, totalConnections: target)
                syncLiveActivityState(
                    profileName: profileName,
                    phase: liveActivityPhase(for: vpnStatus),
                    activeConnections: fallbackProgress,
                    totalConnections: target,
                    relayIP: latestRelayIPFromLogs(),
                    estimatedRemainingSeconds: remaining
                )
            } else {
                connectionProgressText = "0/0"
                syncLiveActivityState(profileName: profileName, phase: liveActivityPhase(for: vpnStatus))
            }
            return
        }

        if let progress = latestConnectionProgressFromLogs() {
            let progressText = "\(progress.active)/\(progress.total)"
            connectionProgressText = progressText
            let estimatedRemainingSeconds = estimatedRemainingSeconds(
                activeConnections: progress.active,
                totalConnections: progress.total
            )
            syncLiveActivityState(
                profileName: profileName,
                phase: liveActivityPhase(for: vpnStatus),
                activeConnections: progress.active,
                totalConnections: progress.total,
                relayIP: latestRelayIPFromLogs(),
                estimatedRemainingSeconds: estimatedRemainingSeconds
            )
        } else if let target {
            let fallbackProgress = vpnStatus == .connected ? target : 0
            connectionProgressText = "\(fallbackProgress)/\(target)"
            syncLiveActivityState(
                profileName: profileName,
                phase: liveActivityPhase(for: vpnStatus),
                activeConnections: fallbackProgress,
                totalConnections: target,
                relayIP: latestRelayIPFromLogs(),
                estimatedRemainingSeconds: estimatedRemainingSeconds(activeConnections: fallbackProgress, totalConnections: target)
            )
        } else {
            connectionProgressText = "0/0"
            syncLiveActivityState(profileName: profileName, phase: liveActivityPhase(for: vpnStatus))
        }

        if vpnStatus == .connected {
            let currentActiveConnections = latestConnectionProgressFromLogs()?.active ?? 0
            if lastSpeedMeasurementActiveConnections == nil || currentActiveConnections > (lastSpeedMeasurementActiveConnections ?? -1) {
                requestSpeedMeasurement(profileName: profileName, activeConnections: currentActiveConnections)
            }
        } else {
            cancelSpeedTest()
        }
    }

    private func handleWidgetURL(_ url: URL) -> Bool {
        guard url.scheme == "vbridge" else {
            return false
        }

        switch url.host?.lowercased() {
        case "refresh":
            refreshWidgetTimelines()
        case "toggle":
            PendingShortcutActionStore.store(.toggle)
        case "connect":
            PendingShortcutActionStore.store(.connect)
        case "disconnect":
            PendingShortcutActionStore.store(.disconnect)
        default:
            break
        }

        schedulePendingShortcutActionConsumption()
        return true
    }

    private func refreshWidgetTimelines() {
#if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: "VBridgeWidget")
#endif
    }

    private func widgetRefreshSignature() -> String {
        guard let snapshot = VBridgeLiveActivityStore.load() else {
            return ""
        }

        let content = snapshot.content
        return [
            snapshot.profileName,
            content.phase.rawValue,
            content.progressText ?? "",
            content.relayIP ?? "",
            content.estimatedRemainingSeconds.map(String.init) ?? "",
            ISO8601DateFormatter().string(from: content.updatedAt)
        ].joined(separator: "|")
    }

    private func schedulePendingShortcutActionConsumption() {
        pendingShortcutActionTask?.cancel()
        pendingShortcutActionTask = Task {
            for _ in 0..<6 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                if await MainActor.run(body: consumePendingShortcutActionIfReady) {
                    return
                }
            }
        }
    }

    @discardableResult
    private func consumePendingShortcutActionIfReady() -> Bool {
        guard hasLoadedInitialStatus else {
            return false
        }
        guard let action = PendingShortcutActionStore.consume() else {
            return false
        }

        switch action {
        case .toggle:
            toggleTunnel()
        case .connect:
            if vpnStatus == .disconnected || vpnStatus == .invalid {
                toggleTunnel()
            }
        case .disconnect:
            if vpnStatus == .connected || vpnStatus == .connecting || vpnStatus == .reasserting {
                toggleTunnel()
            }
        }
        return true
    }

    private func latestConnectionProgressFromLogs() -> (active: Int, total: Int)? {
        for line in SharedLogger.readLogs().reversed() {
            guard let range = line.range(of: "Connected workers ") else { continue }
            let suffix = line[range.upperBound...]
            let value = suffix.split(separator: " ").first.map(String.init) ?? String(suffix)
            let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, let active = Int(parts[0]), let total = Int(parts[1]) else { continue }
            return (active, total)
        }
        return nil
    }

    private func latestRelayIPFromLogs() -> String? {
        for line in SharedLogger.readLogs().reversed() {
            guard let range = line.range(of: "relayed-address=") else { continue }
            let suffix = line[range.upperBound...]
            let value = String(suffix).split(separator: " ").first.map(String.init) ?? String(suffix)
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private func estimatedRemainingSeconds(
        activeConnections: Int,
        totalConnections: Int,
    ) -> Int? {
        guard let connectionStartedAt else { return nil }
        guard totalConnections > 0 else { return nil }
        guard activeConnections >= 0 else { return nil }

        let fraction = Double(activeConnections) / Double(totalConnections)
        guard fraction > 0, fraction < 1 else { return nil }

        let elapsed = Date().timeIntervalSince(connectionStartedAt)
        guard elapsed > 0 else { return nil }

        let estimatedTotal = elapsed / fraction
        let remaining = max(Int((estimatedTotal - elapsed).rounded(.up)), 0)
        return remaining
    }

    private func liveActivityPhase(for status: NEVPNStatus) -> VBridgeLiveActivityPhase {
        switch status {
        case .connected:
            return .connected
        case .connecting, .reasserting:
            return .connecting
        case .disconnecting:
            return .disconnecting
        case .disconnected, .invalid:
            return .disconnected
        @unknown default:
            return .unknown
        }
    }

    private func beginLiveActivity(for profile: VPNProfile, targetWorkers: Int) {
        guard #available(iOS 16.1, *) else { return }
        Task { @MainActor in
            VBridgeLiveActivityCoordinator.shared.sync(
                profileName: profile.name,
                phase: .connecting,
                activeConnections: 0,
                totalConnections: targetWorkers,
                relayIP: nil,
                estimatedRemainingSeconds: nil
            )
        }
    }

    private func resetSpeedTelemetry() {
        speedTestTask?.cancel()
        speedTestTask = nil
        downloadSpeedMbps = nil
        uploadSpeedMbps = nil
        lastSpeedMeasurementActiveConnections = nil
        currentConnectivityPings = ConnectionPingSample.placeholderSamples
    }

    private func requestSpeedMeasurement(profileName: String, activeConnections: Int? = nil) {
        guard #available(iOS 16.1, *) else { return }
        guard vpnStatus == .connected else { return }

        if let activeConnections {
            lastSpeedMeasurementActiveConnections = activeConnections
        } else if lastSpeedMeasurementActiveConnections == nil {
            lastSpeedMeasurementActiveConnections = latestConnectionProgressFromLogs()?.active ?? 0
        }

        speedTestTask?.cancel()
        speedTestTask = Task(priority: .utility) { [profileName] in
            async let pingSamples = ConnectionPingSample.loadAll()
            let result = await runSpeedTest()
            let resolvedPingSamples = await pingSamples
            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.speedTestTask = nil
                guard self.vpnStatus == .connected else { return }
                self.downloadSpeedMbps = result.downloadMbps
                self.uploadSpeedMbps = result.uploadMbps
                self.currentConnectivityPings = resolvedPingSamples

                let progress = self.latestConnectionProgressFromLogs()
                self.syncLiveActivityState(
                    profileName: profileName,
                    phase: .connected,
                    activeConnections: progress?.active,
                    totalConnections: progress?.total,
                    relayIP: self.latestRelayIPFromLogs(),
                    estimatedRemainingSeconds: nil,
                    downloadSpeedMbps: result.downloadMbps,
                    uploadSpeedMbps: result.uploadMbps,
                    pingSamples: resolvedPingSamples.map(\.sharedRepresentation)
                )
                self.refreshWidgetTimelines()

                SharedLogger.info(
                    String(
                        format: "Speed telemetry: download=%@ upload=%@",
                        self.formattedSpeed(result.downloadMbps),
                        self.formattedSpeed(result.uploadMbps)
                    )
                )
            }
        }
    }

    private func syncLiveActivityState(
        profileName: String,
        phase: VBridgeLiveActivityPhase,
        activeConnections: Int? = nil,
        totalConnections: Int? = nil,
        relayIP: String? = nil,
        estimatedRemainingSeconds: Int? = nil,
        downloadSpeedMbps: Double? = nil,
        uploadSpeedMbps: Double? = nil,
        pingSamples: [VBridgePingSample]? = nil
    ) {
        guard #available(iOS 16.1, *) else { return }
        Task { @MainActor in
            VBridgeLiveActivityCoordinator.shared.sync(
                profileName: profileName,
                phase: phase,
                activeConnections: activeConnections,
                totalConnections: totalConnections,
                relayIP: relayIP,
                estimatedRemainingSeconds: estimatedRemainingSeconds,
                downloadSpeedMbps: downloadSpeedMbps,
                uploadSpeedMbps: uploadSpeedMbps,
                pingSamples: pingSamples
            )
        }
    }

    private func syncLiveActivityState(for status: NEVPNStatus) {
        let profileName = store.selectedProfile?.name ?? "VBridge"
        let phase = liveActivityPhase(for: status)
        let progress = latestConnectionProgressFromLogs()

        if phase == .disconnected {
            cancelSpeedTest()
            resetSpeedTelemetry()
            endLiveActivity(profileName: profileName, immediate: true)
            return
        }

        syncLiveActivityState(
            profileName: profileName,
            phase: phase,
            activeConnections: progress?.active,
            totalConnections: progress?.total,
            relayIP: latestRelayIPFromLogs(),
            estimatedRemainingSeconds: progress.flatMap {
                estimatedRemainingSeconds(activeConnections: $0.active, totalConnections: $0.total)
            }
        )

        if phase != .connected {
            cancelSpeedTest()
            resetSpeedTelemetry()
        }
    }

    private func endLiveActivity(profileName: String? = nil, immediate: Bool) {
        guard #available(iOS 16.1, *) else { return }
        let resolvedProfileName = profileName ?? store.selectedProfile?.name ?? "VBridge"
        resetSpeedTelemetry()
        Task { @MainActor in
            VBridgeLiveActivityCoordinator.shared.end(
                profileName: resolvedProfileName,
                finalPhase: .disconnected,
                immediate: immediate
            )
        }
    }

    private func cancelSpeedTest() {
        speedTestTask?.cancel()
        speedTestTask = nil
    }

    private func runSpeedTest() async -> (downloadMbps: Double?, uploadMbps: Double?) {
        guard let firstSample = await sampleRuntimeTransferBytes() else {
            return (nil, nil)
        }

        let start = Date()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard !Task.isCancelled else { return (nil, nil) }

        guard let secondSample = await sampleRuntimeTransferBytes() else {
            return (nil, nil)
        }

        let elapsed = max(Date().timeIntervalSince(start), 0.001)
        let downloadDelta = secondSample.downloadBytes >= firstSample.downloadBytes
            ? secondSample.downloadBytes - firstSample.downloadBytes
            : 0
        let uploadDelta = secondSample.uploadBytes >= firstSample.uploadBytes
            ? secondSample.uploadBytes - firstSample.uploadBytes
            : 0

        let downloadMbps = Double(downloadDelta) * 8.0 / elapsed / 1_000_000.0
        let uploadMbps = Double(uploadDelta) * 8.0 / elapsed / 1_000_000.0
        return (downloadMbps, uploadMbps)
    }

    private func telemetryBadge(title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.black.opacity(0.72))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.black.opacity(0.58))
                Text(value)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    private func pingBadge(_ sample: ConnectionPingSample) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(verbatim: sample.badgeText)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                Circle()
                    .fill(sample.dotColor)
                    .frame(width: 5, height: 5)
                Spacer(minLength: 0)
                Text(verbatim: sample.compactLatencyText)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.black.opacity(0.74))
            }

            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(sample.dotCount > index ? sample.dotColor : .black.opacity(0.08))
                        .frame(width: 8, height: 3)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    private var connectionTelemetrySection: some View {
        let statusLabel: String = {
            switch vpnStatus {
            case .connected:
                return "Connected"
            case .connecting, .reasserting:
                return "Connecting"
            default:
                return "Offline"
            }
        }()

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(connectionProgressText ?? "0/0")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.black.opacity(0.78))

                Spacer(minLength: 0)

                Text(statusLabel)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.black.opacity(0.54))
            }

            HStack(spacing: 8) {
                telemetryBadge(
                    title: "Download",
                    value: formattedSpeed(downloadSpeedMbps),
                    systemImage: "arrow.down.circle.fill"
                )

                telemetryBadge(
                    title: "Upload",
                    value: formattedSpeed(uploadSpeedMbps),
                    systemImage: "arrow.up.circle.fill"
                )
            }

            HStack(spacing: 8) {
                ForEach(currentConnectivityPings, id: \.name) { sample in
                    pingBadge(sample)
                }
            }
        }
        .padding(.top, 4)
    }

    private func sampleRuntimeTransferBytes() async -> (downloadBytes: UInt64, uploadBytes: UInt64)? {
        return await withCheckedContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                guard error == nil else {
                    continuation.resume(returning: nil)
                    return
                }

                guard let manager = managers?.first,
                      let session = manager.connection as? NETunnelProviderSession,
                      session.status == .connected else {
                    continuation.resume(returning: nil)
                    return
                }

                guard (try? session.sendProviderMessage(Data([0]), responseHandler: { response in
                    guard let response,
                          let settings = String(data: response, encoding: .utf8),
                          let totals = runtimeTransferBytes(from: settings) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: totals)
                })) != nil else {
                    continuation.resume(returning: nil)
                    return
                }
            }
        }
    }

    private func runtimeTransferBytes(from settings: String) -> (downloadBytes: UInt64, uploadBytes: UInt64)? {
        var totalDownloadBytes: UInt64 = 0
        var totalUploadBytes: UInt64 = 0
        var currentDownloadBytes: UInt64?
        var currentUploadBytes: UInt64?
        var inPeerSection = false
        var sawPeer = false
        var currentPeerStarted = false

        func finalizePeer() {
            guard currentPeerStarted else { return }
            sawPeer = true
            totalDownloadBytes &+= currentDownloadBytes ?? 0
            totalUploadBytes &+= currentUploadBytes ?? 0
            currentDownloadBytes = nil
            currentUploadBytes = nil
            currentPeerStarted = false
        }

        for rawLine in settings.split(omittingEmptySubsequences: false) { $0.isNewline } {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                if inPeerSection {
                    finalizePeer()
                }
                inPeerSection = false
                continue
            }

            guard let equalsIndex = line.firstIndex(of: "=") else { continue }
            let key = line[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: equalsIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)

            if key == "public_key" {
                if inPeerSection {
                    finalizePeer()
                }
                inPeerSection = true
                currentPeerStarted = true
                continue
            }

            guard inPeerSection else { continue }

            if key == "rx_bytes" {
                currentDownloadBytes = UInt64(value)
            } else if key == "tx_bytes" {
                currentUploadBytes = UInt64(value)
            }
        }

        if inPeerSection {
            finalizePeer()
        }

        return sawPeer ? (totalDownloadBytes, totalUploadBytes) : nil
    }

    private func formattedSpeed(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "--" }
        return String(format: "%.1f Mbps", max(value, 0))
    }

    private func effectiveConnectionTarget(for profile: VPNProfile) -> Int {
        isAmneziaObfuscated(profile.wgQuickConfig) ? 1 : max(profile.nValue, 1)
    }

    private func isAmneziaObfuscated(_ config: String) -> Bool {
        let lowered = config.lowercased()
        let markers = [
            "jc =",
            "jmin =",
            "jmax =",
            "s1 =",
            "s2 =",
            "s3 =",
            "s4 =",
            "h1 =",
            "h2 =",
            "h3 =",
            "h4 =",
            "i1 =",
            "i2 =",
            "i3 =",
            "i4 =",
            "i5 ="
        ]
        return markers.contains { lowered.contains($0) }
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
                nValue: config.n > 0 ? config.n : 16,
                wgQuickConfig: config.wg,
                turnHost: config.turnHost ?? "",
                turnPort: config.turnPort ?? "",
                useUdp: config.udp ?? true
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

    private func importFromFilePicker() {
        withAnimation { showImportModal = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            showFileImporter = true
        }
    }

    private func importFromFile(_ url: URL) {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let ext = url.pathExtension.lowercased()
            guard ["conf", "vbridge"].contains(ext) else {
                throw ConfigParseError.invalidScheme
            }

            let data = try Data(contentsOf: url)
            guard let rawText = String(data: data, encoding: .utf8) else {
                throw ConfigParseError.invalidAmneziaConfig("The file is not valid UTF-8 text.")
            }

            let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix(ConfigParser.scheme) || ConfigParser.legacySchemes.contains(where: { trimmed.hasPrefix($0) }) {
                let config = try ConfigParser.parse(from: trimmed)
                let profile = VPNProfile(
                    name: config.name ?? "Profile",
                    vkLink: config.turn,
                    peerAddr: config.peer,
                    listenAddr: config.listen,
                    nValue: config.n > 0 ? config.n : 16,
                    wgQuickConfig: config.wg,
                    turnHost: config.turnHost ?? "",
                    turnPort: config.turnPort ?? "",
                    useUdp: config.udp ?? true
                )
                store.addProfile(profile)
                SharedLogger.info("Profile \"\(store.selectedProfile?.name ?? "")\" imported from file")
                showAlert(title: "Success", message: "Profile \"\(store.selectedProfile?.name ?? "")\" imported.")
                return
            }

            let config = try ConfigParser.parseAmnezia(from: trimmed)
            let profileName = uniqueProfileName(from: url.deletingPathExtension().lastPathComponent)
            let profile = VPNProfile(
                name: profileName,
                vkLink: "",
                peerAddr: config.peerAddr,
                listenAddr: "127.0.0.1:9000",
                nValue: 16,
                wgQuickConfig: config.wgQuickConfig,
                turnHost: "",
                turnPort: "",
                useUdp: true
            )
            store.addProfile(profile)
            SharedLogger.info("Amnezia profile \"\(store.selectedProfile?.name ?? "")\" imported from file")
            showAlert(title: "Success", message: "Amnezia profile \"\(store.selectedProfile?.name ?? "")\" imported.")
        } catch {
            SharedLogger.error("File import failed: \(error.localizedDescription)")
            showAlert(title: "Import Error", message: error.localizedDescription)
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

    private func showAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showingAlert = true
    }

    private func startConnectWatchdog() {
        cancelConnectWatchdog()
        connectWatchdogTask = Task {
            try? await Task.sleep(nanoseconds: connectWatchdogTimeout * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard vpnStatus == .connecting else { return }

                SharedLogger.error("Connection timeout while waiting for tunnel readiness")
                app.turnOffTunnel()
                vpnStatus = .disconnected
                presentConnectionIssue(
                    title: "Connection Timeout",
                    message: "Tunnel startup timed out (\(connectWatchdogTimeout)s). Check Logs and Captcha flow, then try again."
                )
            }
        }
    }

    private func cancelConnectWatchdog() {
        connectWatchdogTask?.cancel()
        connectWatchdogTask = nil
    }

    private func presentConnectionIssue(title: String, message: String) {
        DispatchQueue.main.async {
            if self.scenePhase == .active {
                self.showAlert(title: title, message: message)
            } else {
                UserNotificationDispatcher.shared.notifyConnectionIssue(title: title, message: message)
            }
        }
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

    private func uniqueProfileName(from candidate: String) -> String {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Profile" : store.uniqueName(for: trimmed)
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
