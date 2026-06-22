import SwiftUI
import NetworkExtension
import UniformTypeIdentifiers
import WebKit
import WireGuardKitGo
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

    init(name: String, latencyMs: Int?) {
        self.name = name
        self.latencyMs = latencyMs
    }

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

private struct PreBootstrapCaptchaView: View {
    let url: String
    let onToken: (String) -> Void
    let onLimit: () -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let targetURL = URL(string: url) {
                    PreBootstrapCaptchaWebView(
                        url: targetURL,
                        onToken: { token in
                            onToken(token)
                            dismiss()
                        },
                        onLimit: onLimit
                    )
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 36, weight: .semibold))
                        Text("Invalid captcha URL")
                            .font(.headline)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Captcha")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct PreBootstrapCaptchaWebView: UIViewRepresentable {
    let url: URL
    let onToken: (String) -> Void
    let onLimit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onToken: onToken, onLimit: onLimit)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()

        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "captchaToken")
        contentController.addUserScript(WKUserScript(
            source: Self.captureScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        configuration.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private let onToken: (String) -> Void
        private let onLimit: () -> Void
        private var didResolve = false

        init(onToken: @escaping (String) -> Void, onLimit: @escaping () -> Void) {
            self.onToken = onToken
            self.onLimit = onLimit
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? String else { return }
            if body.hasPrefix("token:"), !didResolve {
                didResolve = true
                onToken(String(body.dropFirst("token:".count)))
            } else if body.hasPrefix("state:limit") {
                onLimit()
            }
        }
    }

    private static let captureScript = """
    (function() {
        var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.captchaToken;
        if (!h) return;

        function inspect(data) {
            try {
                if (data && data.response && data.response.success_token) {
                    h.postMessage('token:' + data.response.success_token);
                } else if (data && data.response && data.response.status === 'ERROR_LIMIT') {
                    h.postMessage('state:limit:api_error_limit');
                }
            } catch (e) {}
        }

        var origFetch = window.fetch;
        if (origFetch) {
            window.fetch = function() {
                var url = arguments[0];
                if (typeof url === 'object' && url.url) url = url.url;
                var urlStr = String(url || '');
                var p = origFetch.apply(this, arguments);
                if (urlStr.indexOf('captchaNotRobot.check') !== -1) {
                    p.then(function(response) {
                        return response.clone().json();
                    }).then(inspect).catch(function() {});
                }
                return p;
            };
        }

        var origOpen = XMLHttpRequest.prototype.open;
        var origSend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open = function(method, url) {
            this._vbridgeURL = String(url || '');
            return origOpen.apply(this, arguments);
        };
        XMLHttpRequest.prototype.send = function() {
            var xhr = this;
            if ((xhr._vbridgeURL || '').indexOf('captchaNotRobot.check') !== -1) {
                xhr.addEventListener('load', function() {
                    try { inspect(JSON.parse(xhr.responseText)); } catch(e) {}
                });
            }
            return origSend.apply(this, arguments);
        };
    })();
    """
}

private struct SpeedMeasurementResult {
    var downloadMbps: Double?
    var uploadMbps: Double?
    var ispName: String?
    var ipAddress: String?
}

private struct CaptchaRecoveryRequest: Codable, Equatable {
    let id: String
    let reason: String
    let createdAt: TimeInterval
}

private struct PreBootstrapCaptchaChallenge: Identifiable, Equatable {
    let id = UUID()
    let url: String
}

private enum PreBootstrapCaptchaResult {
    case solved(String)
    case refresh
    case dismissed
}

private enum PreBootstrapProbeResult {
    case ok(SeededTURNCredentials)
    case captcha(url: String, sid: String, ts: Double, attempt: Double, token1: String, clientID: String, isRateLimit: Bool)
    case error(String)
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
    @State private var showSplitTunnelSheet = false
    @StateObject private var captchaBridge = CaptchaBridge()
    @State private var didCheckForUpdates = false
    @State private var isDownloadingUpdate = false
    @State private var isCheckingUpdate = false
    @State private var isUserInitiatedDisconnect = false
    @State private var hasLoadedInitialStatus = false
    @State private var connectionProgressText: String?
    @State private var downloadSpeedMbps: Double?
    @State private var uploadSpeedMbps: Double?
    @State private var speedTestISPName: String?
    @State private var speedTestIPAddress: String?
    @State private var connectionStartedAt: Date?
    @State private var lastWidgetRefreshSignature = ""
    @State private var logMonitoringTask: Task<Void, Never>?
    @State private var speedTestTask: Task<Void, Never>?
    @State private var speedTestDebounceTask: Task<Void, Never>?
    @State private var lastSpeedMeasurementActiveConnections: Int?
    @State private var speedTestNeedsRerun = false
    @State private var speedTestRerunProfileName: String?
    @State private var currentConnectivityPings: [ConnectionPingSample] = ConnectionPingSample.placeholderSamples
    @State private var pendingShortcutActionTask: Task<Void, Never>?
    @State private var captchaRecoveryRestartCount = 0
    @State private var lastHandledCaptchaRecoveryID: String?
    @State private var preBootstrapCaptcha: PreBootstrapCaptchaChallenge?
    @State private var preBootstrapCaptchaContinuation: CheckedContinuation<PreBootstrapCaptchaResult, Never>?

    private let connectWatchdogTimeout: UInt64 = 180
    private static let amneziaConfType = UTType(filenameExtension: "conf", conformingTo: .data)
    private static let vbridgeType = UTType(filenameExtension: "vbridge", conformingTo: .data)
    private static let importFileTypes: [UTType] = [
        Self.amneziaConfType,
        Self.vbridgeType
    ].compactMap { $0 }

    var body: some View {
        NavigationStack {
            rootContent
            .overlay {
                if showImportModal {
                    importModalView
                }
            }
            .toolbar {
                contentToolbar
            }
            .sheet(item: $settingsSheet) { sheet in
                NavigationStack {
                    SettingsView(store: store, profileID: sheet.profileID, isNewProfile: sheet.isNew)
                }
            }
            .sheet(isPresented: $showSplitTunnelSheet) {
                NavigationStack {
                    SplitTunnelSettingsView(showsDoneButton: true)
                }
            }
            .sheet(item: $captchaBridge.activeRequest, onDismiss: {
                captchaBridge.clear()
            }) { request in
                CaptchaSolverView(request: request) {
                    captchaBridge.clear()
                }
            }
            .sheet(item: $preBootstrapCaptcha, onDismiss: {
                completePreBootstrapCaptcha(.dismissed)
            }) { challenge in
                PreBootstrapCaptchaView(
                    url: challenge.url,
                    onToken: { token in
                        completePreBootstrapCaptcha(.solved(token))
                    },
                    onLimit: {
                        completePreBootstrapCaptcha(.refresh)
                    },
                    onCancel: {
                        completePreBootstrapCaptcha(.dismissed)
                    }
                )
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
                if handleConnectionURL(url) {
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
                        captchaRecoveryRestartCount = 0
                        clearCaptchaRecoveryRequest()
                        UserNotificationDispatcher.shared.clearConnectionIssueNotification()
                    } else if newStatus == .disconnected, isUserInitiatedDisconnect {
                        isUserInitiatedDisconnect = false
                        captchaRecoveryRestartCount = 0
                        clearCaptchaRecoveryRequest()
                        UserNotificationDispatcher.shared.clearConnectionIssueNotification()
                        endLiveActivity(immediate: true)
                    } else if newStatus == .disconnected {
                        handleCaptchaRecoveryIfNeeded()
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

    private var rootContent: some View {
        ZStack {
            backgroundGradient

            VStack(spacing: 20) {
                headerSection
                profilePickerSection
                Spacer(minLength: 0)
                actionCardSection
                Spacer()
            }
        }
    }

    private var backgroundGradient: some View {
        ZStack {
            LinearGradient(
                colors: backgroundGradientColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if colorScheme == .dark {
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.035),
                        Color.clear,
                        Color(red: 0.59, green: 0.41, blue: 0.98).opacity(0.08)
                    ],
                    startPoint: .top,
                    endPoint: .bottomTrailing
                )
            }
        }
        .ignoresSafeArea()
    }

    private var backgroundGradientColors: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.08, green: 0.09, blue: 0.13),
                Color(red: 0.12, green: 0.11, blue: 0.18),
                Color(red: 0.18, green: 0.14, blue: 0.30)
            ]
        }

        return [
            Color(red: 0.94, green: 0.93, blue: 0.97).opacity(0.96),
            Color(red: 0.86, green: 0.82, blue: 0.96).opacity(0.92),
            Color(red: 0.66, green: 0.54, blue: 0.97).opacity(0.86)
        ]
    }

    private var headerSection: some View {
        VStack(spacing: 4) {
            Text("VBridge")
                .font(.system(size: 44, weight: .bold, design: .default))
                .foregroundStyle(titleGradient)
                .shadow(color: Color(red: 0.53, green: 0.37, blue: 0.98).opacity(0.22), radius: 10, x: 0, y: 5)

            Text(appVersionText)
                .font(.system(size: 14, weight: .semibold, design: .default))
                .foregroundColor(mainSecondaryForegroundColor)

            connectionTelemetrySection()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .padding(.top, 16)
    }

    private var titleGradient: LinearGradient {
        LinearGradient(
            colors: titleGradientColors,
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var titleGradientColors: [Color] {
        if colorScheme == .dark {
            return [
                .white,
                .white.opacity(0.96),
                .white.opacity(0.90)
            ]
        }

        return [
            Color(red: 0.32, green: 0.30, blue: 0.40),
            Color(red: 0.53, green: 0.37, blue: 0.98),
            Color(red: 0.40, green: 0.48, blue: 0.96)
        ]
    }

    private var appVersionText: String {
        "v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")"
    }

    @ViewBuilder
    private var profilePickerSection: some View {
        if !store.profiles.isEmpty {
            profilePicker
                .disabled(vpnStatus != .disconnected)
                .padding(16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(cardBorderColor, lineWidth: 1)
                )
                .padding(.horizontal, 20)
        }
    }

    private var actionCardSection: some View {
        VStack(spacing: 22) {
            tunnelStatusIcon
            updateButton
            connectButton
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(cardBorderColor, lineWidth: 1)
        )
        .padding(.horizontal, 20)
    }

    private var cardBorderColor: Color {
        if colorScheme == .dark {
            return Color.white.opacity(0.12)
        }
        return Color(red: 0.53, green: 0.37, blue: 0.98).opacity(0.16)
    }

    private var mainForegroundColor: Color {
        colorScheme == .dark ? .white : .primary
    }

    private var mainSecondaryForegroundColor: Color {
        colorScheme == .dark ? .white.opacity(0.72) : .secondary
    }

    private func toolbarForegroundColor(isEnabled: Bool = true) -> Color {
        if colorScheme == .dark {
            return isEnabled ? .white : .white.opacity(0.45)
        }
        return isEnabled ? .primary : .secondary
    }

    private var tunnelStatusIcon: some View {
        Image(systemName: vpnStatus == .connected ? "lock.shield.fill" : "lock.shield")
            .resizable()
            .scaledToFit()
            .frame(width: 112, height: 112)
            .foregroundColor(iconColor)
            .shadow(color: iconColor.opacity(0.4), radius: vpnStatus == .connected ? 20 : 0)
            .scaleEffect(vpnStatus == .connecting ? 1.08 : 1.0)
            .animation(vpnStatus == .connecting ? .easeInOut(duration: 1).repeatForever() : .default, value: vpnStatus)
    }

    private var updateButton: some View {
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

                Text(updateButtonText)
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
    }

    private var updateButtonText: String {
        if isDownloadingUpdate {
            return "Downloading update..."
        }
        if isCheckingUpdate {
            return "Checking..."
        }
        return "Check update"
    }

    private var connectButton: some View {
        Button(action: { toggleTunnel() }) {
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

    @ToolbarContentBuilder
    private var contentToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button(action: {
                if vpnStatus == .disconnected {
                    withAnimation { showImportModal = true }
                }
            }) {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(toolbarForegroundColor(isEnabled: vpnStatus == .disconnected))
            }
        }

        ToolbarItemGroup(placement: .navigationBarTrailing) {
            let canEditProfile = vpnStatus == .disconnected && store.selectedProfile != nil

            Button(action: {
                guard let id = store.selectedProfileID else { return }
                if vpnStatus == .disconnected {
                    settingsSheet = SettingsSheet(profileID: id, isNew: false)
                }
            }) {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3)
                    .foregroundColor(toolbarForegroundColor(isEnabled: canEditProfile))
            }

            Button(action: {
                if vpnStatus == .disconnected {
                    showSplitTunnelSheet = true
                }
            }) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.title3)
                    .foregroundColor(toolbarForegroundColor(isEnabled: vpnStatus == .disconnected))
            }

            NavigationLink(destination: GlobalSettingsView()) {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .foregroundColor(toolbarForegroundColor())
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
            .foregroundColor(mainForegroundColor)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.22) : Color.secondary.opacity(0.4), lineWidth: 1)
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
        if colorScheme == .dark {
            return .white
        }

        switch vpnStatus {
        case .connected: return .green
        case .connecting, .disconnecting: return .orange
        default: return Color(red: 0.53, green: 0.37, blue: 0.98)
        }
    }

    private var updateButtonBackground: Color {
        if colorScheme == .dark {
            return Color(red: 0.38, green: 0.28, blue: 0.72).opacity(0.58)
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
            return profile.transportMode == .wdtt
                ? "Please provide a valid VK call URL or hash."
                : "Please provide a valid TURN Server URL."
        }
        if profile.peerAddr.isEmpty {
            return "Please provide a valid Peer Address."
        }
        if profile.transportMode != .wdtt, profile.listenAddr.isEmpty {
            return "Please provide a valid Listen Address."
        }
        if profile.transportMode != .wdtt, profile.wgQuickConfig.isEmpty {
            return "Please provide a valid WireGuard configuration."
        }
        if profile.transportMode == .srtpCommunity, profile.wrapKeyHex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Please provide a valid SRTP-Community WRAP key."
        }
        if profile.transportMode == .wdtt, profile.wdttPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Please provide a valid WDTT password."
        }
        return nil
    }

    private func toggleTunnel(resetCaptchaRecoveryState: Bool = true) {
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
            if resetCaptchaRecoveryState {
                captchaRecoveryRestartCount = 0
                clearCaptchaRecoveryRequest()
            }
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
            Task {
                do {
                    let seededTURN = try await prepareSeededTURNIfNeeded(for: profile)
                    await MainActor.run {
                        guard vpnStatus == .connecting else { return }
                        startConfiguredTunnel(
                            profile: profile,
                            listenAddr: effectiveListenAddr,
                            configuredThreadCount: configuredThreadCount,
                            seededTURN: seededTURN
                        )
                    }
                } catch {
                    await MainActor.run {
                        cancelConnectWatchdog()
                        resetSpeedTelemetry()
                        vpnStatus = .disconnected
                        SharedLogger.error("Pre-bootstrap failed: \(error.localizedDescription)")
                        endLiveActivity(profileName: profile.name, immediate: true)
                        presentConnectionIssue(
                            title: "Connection Failed",
                            message: error.localizedDescription
                        )
                        refreshWidgetTimelines()
                    }
                }
            }
            startConnectWatchdog()
        }
    }

    private func startConfiguredTunnel(
        profile: VPNProfile,
        listenAddr: String,
        configuredThreadCount: Int,
        seededTURN: SeededTURNCredentials?
    ) {
        app.turnOnTunnel(
            vkLink: profile.vkLink,
            peerAddr: profile.peerAddr,
            listenAddr: listenAddr,
            nValue: configuredThreadCount,
            credsGroupSize: max(profile.credsGroupSize, 1),
            wgQuickConfig: profile.wgQuickConfig,
            turnHost: profile.turnHost,
            turnPort: profile.turnPort,
            useUdp: profile.useUdp,
            transportMode: profile.transportMode,
            wrapKeyHex: profile.wrapKeyHex,
            wdttPassword: profile.wdttPassword,
            wdttClientKey: profile.wdttClientKey,
            wdttServerKey: profile.wdttServerKey,
            seededTURN: seededTURN
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
    }

    @MainActor
    private func prepareSeededTURNIfNeeded(for profile: VPNProfile) async throws -> SeededTURNCredentials? {
        guard profile.transportMode == .wdtt else { return nil }

        configureGoRuntimeForPreBootstrap()

        if let cached = CredCache.loadValidCred() {
            SharedLogger.info("WDTT pre-bootstrap: using cached TURN cred addr=\(cached.address)")
            return cached
        }

        SharedLogger.info("WDTT pre-bootstrap: no usable cached TURN cred, probing VK before VPN start")

        var savedSID = ""
        var savedKey = ""
        var savedToken1 = ""
        var savedClientID = ""
        var savedTs: Double = 0
        var savedAttempt: Double = 0
        let linkID = vkLinkID(from: profile.vkLink)

        for attempt in 1...5 {
            SharedLogger.info("WDTT pre-bootstrap probe attempt \(attempt)/5")
            let result = await probeVKCreds(
                linkID: linkID,
                savedSID: savedSID,
                savedKey: savedKey,
                savedToken1: savedToken1,
                savedClientID: savedClientID,
                savedTs: savedTs,
                savedAttempt: savedAttempt
            )

            switch result {
            case .ok(let creds):
                if !profile.turnHost.isEmpty, !profile.turnPort.isEmpty {
                    let override = SeededTURNCredentials(
                        address: "\(profile.turnHost):\(profile.turnPort)",
                        username: creds.username,
                        password: creds.password
                    )
                    SharedLogger.info("WDTT pre-bootstrap: TURN override active, using \(override.address)")
                    return override
                }
                SharedLogger.info("WDTT pre-bootstrap: TURN creds acquired addr=\(creds.address)")
                return creds

            case .captcha(let url, let sid, let ts, let captchaAttempt, let token1, let clientID, let isRateLimit):
                if isRateLimit {
                    throw preBootstrapError("VK temporarily rate-limited captcha. Try again in a minute.")
                }
                SharedLogger.warning("WDTT pre-bootstrap: captcha required before VPN start")
                switch await awaitPreBootstrapCaptcha(url: url) {
                case .solved(let token):
                    savedSID = sid
                    savedKey = token
                    savedToken1 = token1
                    savedClientID = clientID
                    savedTs = ts
                    savedAttempt = captchaAttempt
                case .refresh:
                    savedSID = ""
                    savedKey = ""
                    savedToken1 = ""
                    savedClientID = ""
                    savedTs = 0
                    savedAttempt = 0
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                case .dismissed:
                    throw preBootstrapError("Captcha was dismissed before WDTT pre-bootstrap completed.")
                }

            case .error(let message):
                throw preBootstrapError("WDTT pre-bootstrap probe failed: \(message)")
            }
        }

        throw preBootstrapError("WDTT pre-bootstrap exhausted 5 attempts without TURN credentials.")
    }

    private func configureGoRuntimeForPreBootstrap() {
        VBridgeWGSetTimezoneOffset(Int32(TimeZone.current.secondsFromGMT()))
        if let logPath = SharedLogger.logFileURL?.path {
            logPath.withCString {
                VBridgeWGSetLogFilePath($0)
            }
        }
    }

    private func vkLinkID(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let last = url.pathComponents.last, !last.isEmpty, last != "/" {
            return last
        }
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    private func probeVKCreds(
        linkID: String,
        savedSID: String,
        savedKey: String,
        savedToken1: String,
        savedClientID: String,
        savedTs: Double,
        savedAttempt: Double
    ) async -> PreBootstrapProbeResult {
        await Task.detached(priority: .userInitiated) {
            let cResult = linkID.withCString { linkPtr in
                "".withCString { hostIPsPtr in
                    savedSID.withCString { sidPtr in
                        savedKey.withCString { keyPtr in
                            savedToken1.withCString { tokenPtr in
                                savedClientID.withCString { clientIDPtr in
                                    VBridgeWGProbeVKCreds(
                                        linkPtr,
                                        hostIPsPtr,
                                        sidPtr,
                                        keyPtr,
                                        tokenPtr,
                                        clientIDPtr,
                                        savedTs,
                                        savedAttempt
                                    )
                                }
                            }
                        }
                    }
                }
            }

            guard let cResult else {
                return .error("VBridgeWGProbeVKCreds returned NULL")
            }
            defer { free(UnsafeMutableRawPointer(cResult)) }

            let json = String(cString: cResult)
            guard let data = json.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .error("invalid probe JSON: \(String(json.prefix(200)))")
            }

            switch dict["status"] as? String {
            case "ok":
                let creds = SeededTURNCredentials(
                    address: dict["turn_address"] as? String ?? "",
                    username: dict["turn_username"] as? String ?? "",
                    password: dict["turn_password"] as? String ?? ""
                )
                guard !creds.address.isEmpty, !creds.username.isEmpty, !creds.password.isEmpty else {
                    return .error("probe returned empty TURN credentials")
                }
                return .ok(creds)
            case "captcha":
                return .captcha(
                    url: dict["captcha_url"] as? String ?? "",
                    sid: dict["sid"] as? String ?? "",
                    ts: dict["ts"] as? Double ?? 0,
                    attempt: dict["attempt"] as? Double ?? 0,
                    token1: dict["token1"] as? String ?? "",
                    clientID: dict["client_id"] as? String ?? "",
                    isRateLimit: dict["is_rate_limit"] as? Bool ?? false
                )
            default:
                return .error(dict["message"] as? String ?? "unknown probe error")
            }
        }.value
    }

    @MainActor
    private func awaitPreBootstrapCaptcha(url: String) async -> PreBootstrapCaptchaResult {
        await withCheckedContinuation { continuation in
            preBootstrapCaptchaContinuation = continuation
            preBootstrapCaptcha = PreBootstrapCaptchaChallenge(url: url)
        }
    }

    @MainActor
    private func completePreBootstrapCaptcha(_ result: PreBootstrapCaptchaResult) {
        guard let continuation = preBootstrapCaptchaContinuation else { return }
        preBootstrapCaptchaContinuation = nil
        preBootstrapCaptcha = nil
        continuation.resume(returning: result)
    }

    private func preBootstrapError(_ message: String) -> NSError {
        NSError(domain: "VBridge.WDTTPreBootstrap", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func handleCaptchaRecoveryIfNeeded() {
        guard !isUserInitiatedDisconnect else { return }
        guard let request = loadCaptchaRecoveryRequest() else { return }
        guard request.id != lastHandledCaptchaRecoveryID else { return }

        captchaBridge.clear()
        clearCaptchaRecoveryRequest()
        lastHandledCaptchaRecoveryID = request.id

        guard captchaRecoveryRestartCount < 1 else {
            SharedLogger.error("Captcha recovery restart already attempted for current cycle; not retrying automatically")
            presentConnectionIssue(
                title: "Captcha Recovery Failed",
                message: "The tunnel was reset after a captcha failure, but the next start also failed. Try again manually."
            )
            return
        }

        guard store.selectedProfile != nil else {
            SharedLogger.warning("Captcha recovery requested, but no profile is selected")
            return
        }

        captchaRecoveryRestartCount += 1
        SharedLogger.warning("Captcha session failed; clearing local state and restarting tunnel from scratch")
        resetSpeedTelemetry()
        endLiveActivity(immediate: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard self.vpnStatus == .disconnected || self.vpnStatus == .invalid else { return }
            self.restartAfterCaptchaFailure()
        }
    }

    private func restartAfterCaptchaFailure() {
        guard vpnStatus == .disconnected || vpnStatus == .invalid else { return }
        SharedLogger.info("Restarting tunnel after captcha recovery reset")
        toggleTunnel(resetCaptchaRecoveryState: false)
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

    private func handleConnectionURL(_ url: URL) -> Bool {
        let raw = url.absoluteString
        guard raw.lowercased().hasPrefix(ConfigParser.wdttScheme) else {
            return false
        }

        do {
            let profile = profile(fromWDTT: try ConfigParser.parseWDTT(from: raw), fallbackName: "WDTT")
            store.addProfile(profile)
            SharedLogger.info("WDTT profile \"\(store.selectedProfile?.name ?? "")\" imported from URL")
            showAlert(title: "Success", message: "WDTT profile \"\(store.selectedProfile?.name ?? "")\" imported.")
        } catch {
            SharedLogger.error("URL import failed: \(error.localizedDescription)")
            showAlert(title: "Import Error", message: error.localizedDescription)
        }
        return true
    }

    private func refreshWidgetTimelines() {
#if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: "VBridgeWidget")
#if !targetEnvironment(macCatalyst)
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadControls(ofKind: VBridgeControlKind.connect)
        }
#endif
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
            if await MainActor.run(body: consumePendingShortcutActionIfReady) {
                return
            }

            for _ in 0..<40 {
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
        speedTestDebounceTask?.cancel()
        speedTestDebounceTask = nil
        downloadSpeedMbps = nil
        uploadSpeedMbps = nil
        speedTestISPName = nil
        speedTestIPAddress = nil
        lastSpeedMeasurementActiveConnections = nil
        speedTestNeedsRerun = false
        speedTestRerunProfileName = nil
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

        if speedTestTask != nil {
            speedTestNeedsRerun = true
            speedTestRerunProfileName = profileName
            SharedLogger.info("Speed test already running; queued rerun")
            return
        }

        speedTestNeedsRerun = false
        speedTestRerunProfileName = nil
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
                self.speedTestISPName = result.ispName
                self.speedTestIPAddress = result.ipAddress
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
                    ispName: result.ispName,
                    ipAddress: result.ipAddress,
                    pingSamples: resolvedPingSamples.map(\.sharedRepresentation)
                )
                self.refreshWidgetTimelines()

                SharedLogger.info(
                    String(
                        format: "Speed telemetry: download=%@ upload=%@ isp=%@ ip=%@",
                        self.formattedSpeed(result.downloadMbps),
                        self.formattedSpeed(result.uploadMbps),
                        result.ispName ?? "unknown",
                        result.ipAddress ?? "unknown"
                    )
                )

                let shouldRerun = self.speedTestNeedsRerun && self.vpnStatus == .connected
                let rerunProfileName = self.speedTestRerunProfileName ?? profileName
                self.speedTestNeedsRerun = false
                self.speedTestRerunProfileName = nil

                if shouldRerun {
                    let rerunActiveConnections = self.latestConnectionProgressFromLogs()?.active
                    self.requestSpeedMeasurement(
                        profileName: rerunProfileName,
                        activeConnections: rerunActiveConnections
                    )
                }
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
        ispName: String? = nil,
        ipAddress: String? = nil,
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
                ispName: ispName,
                ipAddress: ipAddress,
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

    private func runSpeedTest() async -> SpeedMeasurementResult {
        SharedLogger.info("Speed test started")

        let speedcheckerResult = await measureSpeedcheckerSpeedTest()

        if let speedcheckerResult, hasMeasuredSpeed(speedcheckerResult) {
            return speedcheckerResult
        }

        if let speedcheckerResult {
            SharedLogger.warning("Speedchecker returned ISP/IP only, continuing with Cloudflare speed test")
            SharedLogger.info(
                String(
                    format: "Speedchecker partial result: download=%@ upload=%@ isp=%@ ip=%@",
                    speedcheckerResult.downloadMbps.map { String(format: "%.1f", $0) } ?? "--",
                    speedcheckerResult.uploadMbps.map { String(format: "%.1f", $0) } ?? "--",
                    speedcheckerResult.ispName ?? "unknown",
                    speedcheckerResult.ipAddress ?? "unknown"
                )
            )
        } else {
            SharedLogger.warning("Speedchecker SDK returned no usable result, falling back to Cloudflare speed test")
        }

        let downloadMbps = await measureCloudflareDownloadSpeed()
        if Task.isCancelled {
            return SpeedMeasurementResult(downloadMbps: nil, uploadMbps: nil, ispName: nil, ipAddress: nil)
        }
        SharedLogger.info("Speed test download result: \(formattedSpeed(downloadMbps))")

        let uploadMbps = await measureCloudflareUploadSpeed()
        if Task.isCancelled {
            return SpeedMeasurementResult(downloadMbps: nil, uploadMbps: nil, ispName: nil, ipAddress: nil)
        }
        SharedLogger.info("Speed test upload result: \(formattedSpeed(uploadMbps))")

        if downloadMbps != nil || uploadMbps != nil {
            return SpeedMeasurementResult(
                downloadMbps: downloadMbps,
                uploadMbps: uploadMbps,
                ispName: speedcheckerResult?.ispName,
                ipAddress: speedcheckerResult?.ipAddress
            )
        }

        SharedLogger.warning("Cloudflare speed test returned no usable result, falling back to runtime byte sampling")
        let runtimeResult = await measureRuntimeSpeedFallback()
        return SpeedMeasurementResult(
            downloadMbps: runtimeResult.downloadMbps,
            uploadMbps: runtimeResult.uploadMbps,
            ispName: speedcheckerResult?.ispName ?? runtimeResult.ispName,
            ipAddress: speedcheckerResult?.ipAddress ?? runtimeResult.ipAddress
        )
    }

    private func hasMeasuredSpeed(_ result: SpeedMeasurementResult) -> Bool {
        result.downloadMbps != nil || result.uploadMbps != nil
    }

    private func measureSpeedcheckerSpeedTest() async -> SpeedMeasurementResult? {
        let service = SpeedcheckerSpeedTestService()
        guard let result = await service.runFreeTest() else {
            return nil
        }

        return SpeedMeasurementResult(
            downloadMbps: result.downloadMbps,
            uploadMbps: result.uploadMbps,
            ispName: result.ispName,
            ipAddress: result.ipAddress
        )
    }

    private func measureCloudflareDownloadSpeed() async -> Double? {
        let candidateSizes = [250_000, 1_000_000, 5_000_000, 10_000_000]
        var lastMbps: Double?
        for size in candidateSizes {
            guard !Task.isCancelled else { return nil }
            SharedLogger.info("Speed test download attempt bytes=\(size)")
            if let sample = await measureCloudflareDownloadSample(byteCount: size) {
                lastMbps = sample.mbps
                SharedLogger.info(
                    String(
                        format: "Speed test download sample bytes=%d elapsed=%.3fs rate=%@",
                        size,
                        sample.elapsed,
                        formattedSpeed(sample.mbps)
                    )
                )
                if sample.elapsed >= 1.25 {
                    return sample.mbps
                }
            } else {
                SharedLogger.warning("Speed test download sample failed for bytes=\(size)")
            }
        }
        return lastMbps
    }

    private func measureCloudflareUploadSpeed() async -> Double? {
        let candidateSizes = [1_000_000, 5_000_000, 10_000_000, 25_000_000]
        var lastMbps: Double?
        for size in candidateSizes {
            guard !Task.isCancelled else { return nil }
            SharedLogger.info("Speed test upload attempt bytes=\(size)")
            if let sample = await measureCloudflareUploadSample(byteCount: size) {
                lastMbps = sample.mbps
                SharedLogger.info(
                    String(
                        format: "Speed test upload sample bytes=%d elapsed=%.3fs rate=%@",
                        size,
                        sample.elapsed,
                        formattedSpeed(sample.mbps)
                    )
                )
                if sample.elapsed >= 1.25 {
                    return sample.mbps
                }
            } else {
                SharedLogger.warning("Speed test upload sample failed for bytes=\(size)")
            }
        }
        return lastMbps
    }

    private func measureCloudflareDownloadSample(byteCount: Int) async -> (mbps: Double, elapsed: TimeInterval)? {
        guard let url = URL(string: "https://speed.cloudflare.com/__down?bytes=\(byteCount)") else {
            return nil
        }

        let expectedTransferSeconds = Double(byteCount) * 8.0 / 250_000.0
        let requestTimeout = min(max(expectedTransferSeconds * 1.5, 20), 90)
        let resourceTimeout = min(requestTimeout + 15, 120)

        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        let session = URLSession(configuration: config)

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: requestTimeout
        )
        request.httpMethod = "GET"
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")

        let start = Date()
        do {
            let (data, response) = try await session.data(for: request)
            guard !Task.isCancelled else { return nil }
            guard let http = response as? HTTPURLResponse, (200...399).contains(http.statusCode) else {
                if let http = response as? HTTPURLResponse {
                    SharedLogger.warning("Speed test download HTTP status=\(http.statusCode) bytes=\(byteCount)")
                } else {
                    SharedLogger.warning("Speed test download returned non-HTTP response for bytes=\(byteCount)")
                }
                return nil
            }
            let elapsed = max(Date().timeIntervalSince(start), 0.001)
            let effectiveBytes = max(data.count, byteCount)
            let mbps = Double(effectiveBytes) * 8.0 / elapsed / 1_000_000.0
            return (mbps, elapsed)
        } catch {
            let nsError = error as NSError
            SharedLogger.warning(
                "Speed test download request failed for bytes=\(byteCount) code=\(nsError.code): \(error.localizedDescription)"
            )
            return nil
        }
    }

    private func measureCloudflareUploadSample(byteCount: Int) async -> (mbps: Double, elapsed: TimeInterval)? {
        guard let url = URL(string: "https://speed.cloudflare.com/__up") else {
            return nil
        }

        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config)

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.httpBody = Data(repeating: 0, count: byteCount)

        let start = Date()
        do {
            let (_, response) = try await session.data(for: request)
            guard !Task.isCancelled else { return nil }
            guard let http = response as? HTTPURLResponse, (200...399).contains(http.statusCode) else {
                if let http = response as? HTTPURLResponse {
                    SharedLogger.warning("Speed test upload HTTP status=\(http.statusCode) bytes=\(byteCount)")
                } else {
                    SharedLogger.warning("Speed test upload returned non-HTTP response for bytes=\(byteCount)")
                }
                return nil
            }
            let elapsed = max(Date().timeIntervalSince(start), 0.001)
            let mbps = Double(byteCount) * 8.0 / elapsed / 1_000_000.0
            return (mbps, elapsed)
        } catch {
            SharedLogger.warning("Speed test upload request failed for bytes=\(byteCount): \(error.localizedDescription)")
            return nil
        }
    }

    private func measureRuntimeSpeedFallback() async -> SpeedMeasurementResult {
        SharedLogger.info("Speed test runtime fallback started")
        guard let firstSample = await sampleRuntimeTransferBytes() else {
            SharedLogger.warning("Speed test runtime fallback failed: could not read first runtime sample")
            return SpeedMeasurementResult(downloadMbps: nil, uploadMbps: nil, ispName: nil, ipAddress: nil)
        }

        let start = Date()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard !Task.isCancelled else {
            return SpeedMeasurementResult(downloadMbps: nil, uploadMbps: nil, ispName: nil, ipAddress: nil)
        }

        guard let secondSample = await sampleRuntimeTransferBytes() else {
            SharedLogger.warning("Speed test runtime fallback failed: could not read second runtime sample")
            return SpeedMeasurementResult(downloadMbps: nil, uploadMbps: nil, ispName: nil, ipAddress: nil)
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
        SharedLogger.info(
            String(
                format: "Speed test runtime fallback result: download=%@ upload=%@",
                formattedSpeed(downloadMbps),
                formattedSpeed(uploadMbps)
            )
        )
        return SpeedMeasurementResult(
            downloadMbps: downloadMbps,
            uploadMbps: uploadMbps,
            ispName: nil,
            ipAddress: nil
        )
    }

    private func telemetryBadge(title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(colorScheme == .dark ? .white.opacity(0.84) : .black.opacity(0.72))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(colorScheme == .dark ? .white.opacity(0.66) : .black.opacity(0.58))
                Text(value)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(colorScheme == .dark ? .white : .black)
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
                .stroke(colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    private func pingBadge(_ sample: ConnectionPingSample) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(verbatim: sample.badgeText)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(colorScheme == .dark ? .white : .black)
                Circle()
                    .fill(sample.dotColor)
                    .frame(width: 5, height: 5)
                Spacer(minLength: 0)
                Text(verbatim: sample.compactLatencyText)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(colorScheme == .dark ? .white.opacity(0.74) : .black.opacity(0.74))
            }

            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(sample.dotCount > index ? sample.dotColor : (colorScheme == .dark ? .white.opacity(0.12) : .black.opacity(0.08)))
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
                .stroke(colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func connectionTelemetrySection() -> some View {
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
                    .foregroundStyle(colorScheme == .dark ? .white.opacity(0.82) : .black.opacity(0.78))

                Spacer(minLength: 0)

                Text(statusLabel)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(colorScheme == .dark ? .white.opacity(0.66) : .black.opacity(0.54))
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

            telemetryBadge(
                title: "ISP",
                value: speedTestISPName ?? "--",
                systemImage: "network"
            )

            telemetryBadge(
                title: "IP",
                value: speedTestIPAddress ?? "--",
                systemImage: "location.fill"
            )

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

        for rawLine in settings.components(separatedBy: .newlines) {
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
        if profile.transportMode == .wg, isAmneziaObfuscated(profile.wgQuickConfig) {
            return 1
        }
        return max(profile.nValue, 1)
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
            let importedProfile: VPNProfile
            if clipboardString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix(ConfigParser.wdttScheme) {
                importedProfile = profile(fromWDTT: try ConfigParser.parseWDTT(from: clipboardString), fallbackName: "WDTT")
            } else {
                importedProfile = profile(fromTurnConfig: try ConfigParser.parse(from: clipboardString), fallbackName: "Profile")
            }
            store.addProfile(importedProfile)
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
            if trimmed.lowercased().hasPrefix(ConfigParser.wdttScheme) {
                let profile = profile(fromWDTT: try ConfigParser.parseWDTT(from: trimmed), fallbackName: uniqueProfileName(from: url.deletingPathExtension().lastPathComponent))
                store.addProfile(profile)
                SharedLogger.info("WDTT profile \"\(store.selectedProfile?.name ?? "")\" imported from file")
                showAlert(title: "Success", message: "WDTT profile \"\(store.selectedProfile?.name ?? "")\" imported.")
                return
            }

            if trimmed.hasPrefix(ConfigParser.scheme) || ConfigParser.legacySchemes.contains(where: { trimmed.hasPrefix($0) }) {
                let profile = profile(fromTurnConfig: try ConfigParser.parse(from: trimmed), fallbackName: "Profile")
                store.addProfile(profile)
                SharedLogger.info("Profile \"\(store.selectedProfile?.name ?? "")\" imported from file")
                showAlert(title: "Success", message: "Profile \"\(store.selectedProfile?.name ?? "")\" imported.")
                return
            }

            let config = try ConfigParser.parseAmnezia(from: trimmed)
            let profileName = uniqueProfileName(from: url.deletingPathExtension().lastPathComponent)
            let profile = VPNProfile(
                name: profileName,
                transportMode: .wg,
                vkLink: "",
                peerAddr: config.peerAddr,
                listenAddr: "127.0.0.1:9000",
                nValue: 30,
                credsGroupSize: 12,
                wgQuickConfig: config.wgQuickConfig,
                turnHost: "",
                turnPort: "",
                useUdp: false
            )
            store.addProfile(profile)
            SharedLogger.info("Amnezia profile \"\(store.selectedProfile?.name ?? "")\" imported from file")
            showAlert(title: "Success", message: "Amnezia profile \"\(store.selectedProfile?.name ?? "")\" imported.")
        } catch {
            SharedLogger.error("File import failed: \(error.localizedDescription)")
            showAlert(title: "Import Error", message: error.localizedDescription)
        }
    }

    private func profile(fromTurnConfig config: TurnConfigImport, fallbackName: String) -> VPNProfile {
        let mode = VPNTransportMode(rawValue: config.mode ?? "") ?? .wg
        return VPNProfile(
            name: config.name ?? fallbackName,
            transportMode: mode,
            vkLink: config.turn,
            peerAddr: config.peer,
            listenAddr: config.listen,
            nValue: config.n > 0 ? config.n : 30,
            credsGroupSize: max(config.credsGroupSize ?? config.streamsPerCred ?? 12, 1),
            wgQuickConfig: config.wg,
            turnHost: config.turnHost ?? "",
            turnPort: config.turnPort ?? "",
            useUdp: config.udp ?? false,
            wrapKeyHex: config.wrapKeyHex ?? "",
            wdttPassword: config.wdttPassword ?? "",
            wdttClientKey: config.wdttClientKey ?? "",
            wdttServerKey: config.wdttServerKey ?? ""
        )
    }

    private func profile(fromWDTT config: WDTTConfigImport, fallbackName: String) -> VPNProfile {
        VPNProfile(
            name: fallbackName,
            transportMode: .wdtt,
            vkLink: config.vkLink,
            peerAddr: config.peerAddr,
            listenAddr: "127.0.0.1:\(config.localPort)",
            nValue: 30,
            credsGroupSize: 12,
            wgQuickConfig: "",
            turnHost: "",
            turnPort: "",
            useUdp: false,
            wdttPassword: config.password,
            wdttClientKey: config.hashes.first ?? "",
            wdttServerKey: config.hashes.dropFirst().joined(separator: ",")
        )
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

    private func loadCaptchaRecoveryRequest() -> CaptchaRecoveryRequest? {
        guard let groupID = SharedLogger.appGroupID,
              let defaults = UserDefaults(suiteName: groupID),
              let data = defaults.data(forKey: "captcha.recovery.request") else {
            return nil
        }
        return try? JSONDecoder().decode(CaptchaRecoveryRequest.self, from: data)
    }

    private func clearCaptchaRecoveryRequest() {
        guard let groupID = SharedLogger.appGroupID,
              let defaults = UserDefaults(suiteName: groupID) else {
            return
        }
        defaults.removeObject(forKey: "captcha.recovery.request")
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
