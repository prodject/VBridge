import Foundation
import AppIntents
import ActivityKit
import WidgetKit
import SwiftUI

private enum WidgetAppGroup {
    static let identifier = "group.com.prodject.vbridge"
}

private enum WidgetActionStore {
    static let suiteName = WidgetAppGroup.identifier
    static let key = "pending.shortcut.action"

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    static func storeConnectAction() {
        defaults?.set("connect", forKey: key)
        defaults?.synchronize()
    }

    static func storeDisconnectAction() {
        defaults?.set("disconnect", forKey: key)
        defaults?.synchronize()
    }
}

@available(iOS 17.0, *)
private struct RefreshVBridgeWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh VBridge Widget"
    static var description = IntentDescription("Refreshes the widget without opening the app.")
    static var openAppWhenRun = false
    static var isDiscoverable = false

    func perform() async throws -> some IntentResult {
        WidgetCenter.shared.reloadTimelines(ofKind: "VBridgeWidget")
        return .result()
    }
}

@available(iOS 17.0, *)
private struct ConnectVBridgeWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "Connect VBridge VPN"
    static var description = IntentDescription("Opens VBridge and connects the tunnel.")
    static var openAppWhenRun = true
    static var isDiscoverable = false

    func perform() async throws -> some IntentResult {
        WidgetActionStore.storeConnectAction()
        return .result()
    }
}

@available(iOS 17.0, *)
private struct DisconnectVBridgeWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "Disconnect VBridge VPN"
    static var description = IntentDescription("Opens VBridge and disconnects the tunnel.")
    static var openAppWhenRun = true
    static var isDiscoverable = false

    func perform() async throws -> some IntentResult {
        WidgetActionStore.storeDisconnectAction()
        return .result()
    }
}

private struct WidgetSnapshot: Equatable {
    enum State: String {
        case connected
        case connecting
        case disconnected
        case unknown
    }

    let profileName: String
    let state: State
    let activeConnections: Int?
    let totalConnections: Int?
    let relayIP: String?
    let estimatedRemainingSeconds: Int?
    let downloadSpeedMbps: Double?
    let uploadSpeedMbps: Double?
    let ispName: String?
    let ipAddress: String?
    let pings: [PingSample]
    let lastUpdated: Date

    var statusLabel: String {
        switch state {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting"
        case .disconnected:
            return "Disconnected"
        case .unknown:
            return "Unknown"
        }
    }

    var statusSymbol: String {
        switch state {
        case .connected:
            return "lock.shield.fill"
        case .connecting:
            return "wifi"
        case .disconnected:
            return "lock.shield"
        case .unknown:
            return "questionmark.circle"
        }
    }

    var statusAccent: Color {
        switch state {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .disconnected:
            return .red
        case .unknown:
            return .secondary
        }
    }

    var connectionsText: String {
        guard let activeConnections, let totalConnections else {
            return "0/0"
        }
        return "\(activeConnections)/\(totalConnections)"
    }

    var relayText: String {
        relayIP ?? "No relay IP"
    }

    var progressFraction: Double? {
        guard let activeConnections, let totalConnections, totalConnections > 0 else {
            return nil
        }
        return min(max(Double(activeConnections) / Double(totalConnections), 0), 1)
    }

    var remainingText: String? {
        guard let estimatedRemainingSeconds else { return nil }
        let clampedSeconds = max(estimatedRemainingSeconds, 0)
        guard clampedSeconds > 0 else {
            return "Almost there"
        }

        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = clampedSeconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = clampedSeconds >= 3600 ? [.pad] : [.dropAll]
        return formatter.string(from: TimeInterval(clampedSeconds))
    }

    var downloadSpeedText: String {
        speedText(downloadSpeedMbps, fallback: "DL --")
    }

    var uploadSpeedText: String {
        speedText(uploadSpeedMbps, fallback: "UL --")
    }

    var speedSummaryText: String {
        "\(downloadSpeedText)  •  \(uploadSpeedText)"
    }

    var ispText: String {
        ispName ?? "ISP --"
    }

    var ipText: String {
        ipAddress ?? "IP --"
    }

    var summaryText: String {
        switch state {
        case .connected:
            return relayIP.map { "Secured via \($0)" } ?? "VPN is up"
        case .connecting:
            if let remainingText {
                return "ETA \(remainingText)"
            }
            return "Negotiating tunnel"
        case .disconnected:
            return "Tap to connect"
        case .unknown:
            return "Waiting for status"
        }
    }

    init(
        profileName: String,
        state: State,
        activeConnections: Int?,
        totalConnections: Int?,
        relayIP: String?,
        estimatedRemainingSeconds: Int?,
        downloadSpeedMbps: Double? = nil,
        uploadSpeedMbps: Double? = nil,
        ispName: String? = nil,
        ipAddress: String? = nil,
        pings: [PingSample],
        lastUpdated: Date
    ) {
        self.profileName = profileName
        self.state = state
        self.activeConnections = activeConnections
        self.totalConnections = totalConnections
        self.relayIP = relayIP
        self.estimatedRemainingSeconds = estimatedRemainingSeconds
        self.downloadSpeedMbps = downloadSpeedMbps
        self.uploadSpeedMbps = uploadSpeedMbps
        self.ispName = ispName
        self.ipAddress = ipAddress
        self.pings = pings
        self.lastUpdated = lastUpdated
    }

    static let placeholder = WidgetSnapshot(
        profileName: "VBridge",
        state: .connected,
        activeConnections: 6,
        totalConnections: 10,
        relayIP: "193.203.43.9",
        estimatedRemainingSeconds: 32,
        downloadSpeedMbps: 18.4,
        uploadSpeedMbps: 5.7,
        ispName: "Fiber ISP",
        ipAddress: "203.0.113.24",
        pings: PingSample.placeholderSamples,
        lastUpdated: .now
    )

    static func load() -> WidgetSnapshot {
        let logSnapshot = loadFromLogs()
        if let sharedSnapshot = VBridgeWidgetSnapshotStore.load() {
            return WidgetSnapshot(sharedSnapshot: sharedSnapshot, fallback: logSnapshot)
        }
        if let liveState = VBridgeLiveActivityStore.load() {
            return WidgetSnapshot(
                liveSnapshot: liveState,
                fallback: logSnapshot
            )
        }

        return logSnapshot ?? WidgetSnapshot(
            profileName: "VBridge",
            state: .unknown,
            activeConnections: nil,
            totalConnections: nil,
            relayIP: nil,
            estimatedRemainingSeconds: nil,
            downloadSpeedMbps: nil,
            uploadSpeedMbps: nil,
            ispName: nil,
            ipAddress: nil,
            pings: PingSample.placeholderSamples,
            lastUpdated: .now
        )
    }

    private static func loadFromLogs() -> WidgetSnapshot? {
        guard let logURL = logURL(),
              let content = try? String(contentsOf: logURL, encoding: .utf8) else {
            return nil
        }

        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }

        var activeConnections: Int?
        var totalConnections: Int?
        var relayIP: String?
        var state: State = .unknown

        for line in lines.reversed() {
            if relayIP == nil, let range = line.range(of: "relayed-address=") {
                let suffix = line[range.upperBound...]
                let value = String(suffix).split(separator: " ").first.map(String.init) ?? String(suffix)
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("["),
                   let endIndex = trimmed.firstIndex(of: "]") {
                    relayIP = String(trimmed[trimmed.index(after: trimmed.startIndex)..<endIndex])
                } else if let lastColon = trimmed.lastIndex(of: ":") {
                    let host = String(trimmed[..<lastColon])
                    let port = String(trimmed[trimmed.index(after: lastColon)...])
                    if !host.isEmpty, !port.isEmpty, port.allSatisfy(\.isNumber) {
                        relayIP = host
                    } else {
                        relayIP = trimmed.isEmpty ? nil : trimmed
                    }
                } else {
                    relayIP = trimmed.isEmpty ? nil : trimmed
                }
            }

            if (activeConnections == nil || totalConnections == nil), let range = line.range(of: "Connected workers ") {
                let suffix = line[range.upperBound...]
                let value = suffix.split(separator: " ").first.map(String.init) ?? String(suffix)
                let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    activeConnections = Int(parts[0])
                    totalConnections = Int(parts[1])
                }
            }

            if state == .unknown, let extracted = stateFromLogLine(line) {
                state = extracted
            }

            if relayIP != nil, activeConnections != nil, totalConnections != nil, state != .unknown {
                break
            }
        }

        let pings = state == .connected ? PingSample.loadAll() : PingSample.placeholderSamples

        return WidgetSnapshot(
            profileName: "VBridge",
            state: state,
            activeConnections: activeConnections,
            totalConnections: totalConnections,
            relayIP: relayIP,
            estimatedRemainingSeconds: nil,
            downloadSpeedMbps: nil,
            uploadSpeedMbps: nil,
            ispName: nil,
            ipAddress: nil,
            pings: pings,
            lastUpdated: .now
        )
    }

    init(liveSnapshot: VBridgeLiveActivitySnapshot) {
        self.init(liveSnapshot: liveSnapshot, fallback: nil)
    }

    init(liveSnapshot: VBridgeLiveActivitySnapshot, fallback: WidgetSnapshot?) {
        let state = State(rawValue: liveSnapshot.content.phase.rawValue) ?? .unknown
        self.profileName = liveSnapshot.profileName
        self.state = state
        self.activeConnections = liveSnapshot.content.activeConnections ?? fallback?.activeConnections
        self.totalConnections = liveSnapshot.content.totalConnections ?? fallback?.totalConnections
        self.relayIP = liveSnapshot.content.relayIP ?? fallback?.relayIP
        self.estimatedRemainingSeconds = liveSnapshot.content.estimatedRemainingSeconds ?? fallback?.estimatedRemainingSeconds
        self.downloadSpeedMbps = liveSnapshot.content.downloadSpeedMbps ?? fallback?.downloadSpeedMbps
        self.uploadSpeedMbps = liveSnapshot.content.uploadSpeedMbps ?? fallback?.uploadSpeedMbps
        self.ispName = liveSnapshot.content.ispName ?? fallback?.ispName
        self.ipAddress = liveSnapshot.content.ipAddress ?? fallback?.ipAddress
        if let livePingSamples = liveSnapshot.content.pingSamples {
            self.pings = livePingSamples.map(PingSample.init(shared:))
        } else if state == .connected {
            self.pings = fallback?.pings ?? PingSample.placeholderSamples
        } else {
            self.pings = fallback?.pings ?? PingSample.placeholderSamples
        }
        self.lastUpdated = liveSnapshot.content.updatedAt
    }

    init(sharedSnapshot: VBridgeWidgetSnapshot, fallback: WidgetSnapshot?) {
        let state = State(rawValue: sharedSnapshot.phase.rawValue) ?? .unknown
        self.profileName = sharedSnapshot.profileName
        self.state = state
        self.activeConnections = sharedSnapshot.activeConnections ?? fallback?.activeConnections
        self.totalConnections = sharedSnapshot.totalConnections ?? fallback?.totalConnections
        self.relayIP = sharedSnapshot.relayIP ?? fallback?.relayIP
        self.estimatedRemainingSeconds = sharedSnapshot.estimatedRemainingSeconds ?? fallback?.estimatedRemainingSeconds
        self.downloadSpeedMbps = sharedSnapshot.downloadSpeedMbps ?? fallback?.downloadSpeedMbps
        self.uploadSpeedMbps = sharedSnapshot.uploadSpeedMbps ?? fallback?.uploadSpeedMbps
        self.ispName = sharedSnapshot.ispName ?? fallback?.ispName
        self.ipAddress = sharedSnapshot.ipAddress ?? fallback?.ipAddress
        if let pingSamples = sharedSnapshot.pingSamples {
            self.pings = pingSamples.map(PingSample.init(shared:))
        } else {
            self.pings = fallback?.pings ?? PingSample.placeholderSamples
        }
        self.lastUpdated = sharedSnapshot.updatedAt
    }

    private func speedText(_ value: Double?, fallback: String) -> String {
        guard let value, value.isFinite else { return fallback }
        return String(format: "%.1f Mbps", max(value, 0))
    }

    private static func logURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetAppGroup.identifier)?
            .appendingPathComponent("vpn_tunnel.log")
    }

    private static func stateFromLogLine(_ line: String) -> State? {
        guard line.contains("VPN status:") else { return nil }
        if line.contains("Connected") { return .connected }
        if line.contains("Connecting") || line.contains("Reasserting") { return .connecting }
        if line.contains("Disconnected") || line.contains("Disconnecting") { return .disconnected }
        return .unknown
    }
}

private struct WidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

private struct PingSample: Equatable {
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

    var latencyText: String {
        guard let latencyMs else { return "offline" }
        return "\(latencyMs) ms"
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

    static let placeholderSamples: [PingSample] = [
        PingSample(name: "Cloudflare", latencyMs: 24),
        PingSample(name: "Google", latencyMs: 41),
        PingSample(name: "Yandex", latencyMs: 69)
    ]

    static func loadAll() -> [PingSample] {
        var results = placeholderSamples
        let group = DispatchGroup()
        let lock = NSLock()

        for (index, target) in targets.enumerated() {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let sample = PingSample(name: target.0, latencyMs: pingLatency(for: target.1))
                lock.lock()
                results[index] = sample
                lock.unlock()
                group.leave()
            }
        }

        _ = group.wait(timeout: .now() + 4)
        return results
    }

    private static func pingLatency(for url: URL) -> Int? {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 3
        let session = URLSession(configuration: config)

        let semaphore = DispatchSemaphore(value: 0)
        var result: Int?
        let start = DispatchTime.now()

        let task = session.dataTask(with: request) { _, response, error in
            defer { semaphore.signal() }
            guard error == nil, let http = response as? HTTPURLResponse else { return }
            guard (200...399).contains(http.statusCode) else { return }
            let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            result = Int(elapsed / 1_000_000)
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 4)
        task.cancel()
        return result
    }
}

private struct WidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> WidgetEntry {
        WidgetEntry(date: .now, snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (WidgetEntry) -> Void) {
        completion(WidgetEntry(date: .now, snapshot: WidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        let snapshot = WidgetSnapshot.load()
        let refreshInterval = snapshot.state == .connected ? 30 : 60
        let refreshDate = Calendar.current.date(byAdding: .second, value: refreshInterval, to: .now) ?? .now.addingTimeInterval(TimeInterval(refreshInterval))
        completion(Timeline(entries: [WidgetEntry(date: .now, snapshot: snapshot)], policy: .after(refreshDate)))
    }
}

private struct WidgetCardView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WidgetEntry

    var body: some View {
        let snapshot = entry.snapshot
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)

            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.20),
                            Color(red: 0.62, green: 0.48, blue: 0.98).opacity(0.16),
                            Color(red: 0.08, green: 0.78, blue: 0.92).opacity(0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Circle()
                .fill(Color.white.opacity(0.22))
                .frame(width: family == .systemSmall ? 116 : 156, height: family == .systemSmall ? 116 : 156)
                .blur(radius: 34)
                .offset(x: family == .systemSmall ? -58 : -82, y: family == .systemSmall ? -46 : -66)

            Circle()
                .fill(Color(red: 0.45, green: 0.26, blue: 0.98).opacity(0.30))
                .frame(width: family == .systemSmall ? 132 : 172, height: family == .systemSmall ? 132 : 172)
                .blur(radius: 32)
                .offset(x: family == .systemSmall ? 62 : 84, y: family == .systemSmall ? 56 : 74)

            Circle()
                .fill(Color(red: 0.38, green: 0.50, blue: 0.98).opacity(0.18))
                .frame(width: family == .systemSmall ? 92 : 124, height: family == .systemSmall ? 92 : 124)
                .blur(radius: 22)
                .offset(x: family == .systemSmall ? 16 : 26, y: family == .systemSmall ? 20 : 26)

            content(snapshot: snapshot)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.24), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 18, x: 0, y: 8)
    }

    @ViewBuilder
    private func content(snapshot: WidgetSnapshot) -> some View {
        switch family {
        case .systemSmall:
            smallLayout(snapshot: snapshot)
        case .systemMedium:
            mediumLayout(snapshot: snapshot)
        default:
            largeLayout(snapshot: snapshot)
        }
    }

    private func smallLayout(snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.profileName)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(snapshot.statusLabel)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                }

                Spacer(minLength: 0)

                Image(systemName: snapshot.statusSymbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(snapshot.statusAccent)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.connectionsText)
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                Text(snapshot.summaryText)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.70))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            if snapshot.state == .connecting {
                ProgressView(value: snapshot.progressFraction ?? 0)
                    .tint(.white)
                    .progressViewStyle(.linear)
                    .scaleEffect(x: 1, y: 0.7, anchor: .center)
            }

            HStack(spacing: 5) {
                Image(systemName: "network")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.68))
                Text(snapshot.relayText)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }

            metricsSection(snapshot: snapshot, compactPings: true, showISP: false, showIP: false)

            Spacer(minLength: 0)

            refreshRow()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
    }

    private func mediumLayout(snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.profileName)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(snapshot.statusLabel)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                }

                Spacer(minLength: 0)

                Image(systemName: snapshot.statusSymbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(snapshot.statusAccent)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(snapshot.connectionsText)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(snapshot.summaryText)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.70))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            metricsSection(snapshot: snapshot, compactPings: true, showISP: true, showIP: true)

            HStack(spacing: 5) {
                Image(systemName: "network")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.68))
                Text(snapshot.relayText)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }

            if snapshot.state == .connecting {
                ProgressView(value: snapshot.progressFraction ?? 0)
                    .tint(.white)
                    .progressViewStyle(.linear)
                    .scaleEffect(x: 1, y: 0.7, anchor: .center)

                Text(snapshot.remainingText ?? "Working")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.78))
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
    }

    private func largeLayout(snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.profileName)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(snapshot.statusLabel)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                }

                Spacer(minLength: 0)

                Image(systemName: snapshot.statusSymbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(snapshot.statusAccent)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(snapshot.connectionsText)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)

                Text(snapshot.summaryText)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.70))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            HStack(spacing: 5) {
                Image(systemName: "network")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.68))
                Text(snapshot.relayText)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }

            if snapshot.state == .connecting {
                ProgressView(value: snapshot.progressFraction ?? 0)
                    .tint(.white)
                    .progressViewStyle(.linear)
                    .scaleEffect(x: 1, y: 0.7, anchor: .center)

                Text(snapshot.remainingText ?? "Working")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.78))
            }

            HStack(spacing: 8) {
                if #available(iOS 17.0, *) {
                    Button(intent: RefreshVBridgeWidgetIntent()) {
                        actionButtonLabel(title: "Refresh", systemImage: "arrow.clockwise.circle.fill")
                    }
                    .buttonStyle(.plain)

                    Button(intent: ConnectVBridgeWidgetIntent()) {
                        actionButtonLabel(title: "Connect", systemImage: "lock.shield.fill")
                    }
                    .buttonStyle(.plain)
                } else {
                    actionButtonLabel(title: "Refresh", systemImage: "arrow.clockwise.circle.fill")
                    actionButtonLabel(title: "Connect", systemImage: "lock.shield.fill")
                }
            }

            metricsSection(snapshot: snapshot, compactPings: false, showISP: true, showIP: true)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
    }

    private func metricsSection(snapshot: WidgetSnapshot, compactPings: Bool, showISP: Bool, showIP: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                metricChip(title: "Download", value: snapshot.downloadSpeedText, systemImage: "arrow.down.circle.fill")
                metricChip(title: "Upload", value: snapshot.uploadSpeedText, systemImage: "arrow.up.circle.fill")
                if showISP {
                    metricChip(title: "ISP", value: snapshot.ispText, systemImage: "network")
                }
                if showIP {
                    metricChip(title: "IP", value: snapshot.ipText, systemImage: "location.fill")
                }
            }

            HStack(alignment: .top, spacing: 6) {
                if compactPings {
                    ForEach(snapshot.pings, id: \.name) { ping in
                        miniPingBadge(sample: ping)
                    }
                } else {
                    ForEach(snapshot.pings, id: \.name) { ping in
                        PingCompactView(sample: ping)
                    }
                }
            }
        }
    }

    private func metricChip(title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.86))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.70))
                Text(value)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
    }

    private func miniPingBadge(sample: PingSample) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(verbatim: sample.badgeText)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Circle()
                    .fill(sample.dotColor)
                    .frame(width: 4, height: 4)
                Text(verbatim: sample.compactLatencyText)
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.82))
            }

            HStack(spacing: 1.5) {
                ForEach(0..<5, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(sample.dotCount > index ? sample.dotColor : .white.opacity(0.14))
                        .frame(width: 6, height: 2.5)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    @ViewBuilder
    private func refreshRow() -> some View {
        if #available(iOS 17.0, *) {
            Button(intent: RefreshVBridgeWidgetIntent()) {
                HStack {
                    Text("Tap to refresh")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.84))

                    Spacer(minLength: 0)

                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.86))
                }
            }
            .buttonStyle(.plain)
        } else {
            HStack {
                Text("Open app to refresh")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.84))

                Spacer(minLength: 0)

                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.86))
            }
        }
    }

    private func actionButtonLabel(title: String, systemImage: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.84))

            Spacer(minLength: 0)

            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.86))
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct PingCompactView: View {
    let sample: PingSample

    var body: some View {
        let badgeText = sample.badgeText
        let latencyText = sample.compactLatencyText
        let dotColor = sample.dotColor
        let activeDotCount = sample.dotCount
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(verbatim: badgeText)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Circle()
                    .fill(dotColor)
                    .frame(width: 5, height: 5)
                Spacer(minLength: 0)
                Text(verbatim: latencyText)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
            }

            HStack(spacing: 2) {
                Capsule(style: .continuous)
                    .fill(activeDotCount > 0 ? dotColor : .white.opacity(0.16))
                    .frame(width: 8, height: 3)
                Capsule(style: .continuous)
                    .fill(activeDotCount > 1 ? dotColor : .white.opacity(0.16))
                    .frame(width: 8, height: 3)
                Capsule(style: .continuous)
                    .fill(activeDotCount > 2 ? dotColor : .white.opacity(0.16))
                    .frame(width: 8, height: 3)
                Capsule(style: .continuous)
                    .fill(activeDotCount > 3 ? dotColor : .white.opacity(0.16))
                    .frame(width: 8, height: 3)
                Capsule(style: .continuous)
                    .fill(activeDotCount > 4 ? dotColor : .white.opacity(0.16))
                    .frame(width: 8, height: 3)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 0)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@available(iOS 16.1, *)
private struct VBridgeLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VBridgeVPNLiveActivityAttributes.self) { context in
            liveActivityLockScreenView(
                profileName: context.attributes.profileName,
                state: context.state
            )
            .activityBackgroundTint(Color.black.opacity(0.82))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    liveActivityStatusBadge(
                        phase: context.state.phase,
                        statusSymbol: liveActivityStatusSymbol(phase: context.state.phase),
                        statusAccent: liveActivityStatusAccent(phase: context.state.phase)
                    )
                        .padding(.leading, 2)
                }

                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.attributes.profileName)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)

                        Text(context.state.progressText ?? context.state.phase.displayTitle)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .padding(.horizontal, 2)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Text(String(context.state.activeConnections ?? 0))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    liveActivityExpandedBottomView(state: context.state)
                }
            } compactLeading: {
                Text("VB")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            } compactTrailing: {
                Image(systemName: context.state.phase == .connected ? "lock.fill" : "wifi")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            } minimal: {
                Circle()
                    .fill(liveActivityTint(for: context.state.phase))
                    .frame(width: 9, height: 9)
            }
            .keylineTint(liveActivityTint(for: context.state.phase))
        }
    }

    private func liveActivityLockScreenView(
        profileName: String,
        state: VBridgeVPNLiveActivityAttributes.ContentState
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            liveActivityHeader(
                profileName: profileName,
                state: WidgetSnapshot.State(rawValue: state.phase.rawValue) ?? .unknown,
                statusLabel: state.phase.displayTitle,
                statusSymbol: liveActivityStatusSymbol(phase: state.phase),
                statusAccent: liveActivityStatusAccent(phase: state.phase)
            )

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(state.progressText ?? "0/0")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                VStack(alignment: .leading, spacing: 2) {
                    Text(state.phase.displayTitle)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)

                    Text(state.remainingText ?? state.relayText)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }
            }

            ProgressView(value: state.progressFraction ?? 0)
                .tint(liveActivityTint(for: state.phase))
                .progressViewStyle(.linear)

            HStack(spacing: 6) {
                speedChip(title: "Download", value: state.downloadSpeedText ?? "DL --")
                speedChip(title: "Upload", value: state.uploadSpeedText ?? "UL --")
            }

            HStack(spacing: 6) {
                Image(systemName: "network")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Text("ISP")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.68))
                Text(state.ispText)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                Image(systemName: "location.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Text("IP")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.68))
                Text(state.ipAddressText)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                Image(systemName: "network")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Text(state.relayText)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func liveActivityStatusSymbol(
        phase: VBridgeLiveActivityPhase
    ) -> String {
        switch phase {
        case .connected:
            return "lock.shield.fill"
        case .connecting:
            return "wifi"
        case .disconnecting:
            return "wifi.slash"
        case .disconnected:
            return "lock.shield"
        case .unknown:
            return "questionmark.circle"
        }
    }

    private func liveActivityStatusAccent(
        phase: VBridgeLiveActivityPhase
    ) -> Color {
        switch phase {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .disconnecting:
            return .orange
        case .disconnected:
            return .red
        case .unknown:
            return .secondary
        }
    }

    private func liveActivityHeader(
        profileName: String,
        state: WidgetSnapshot.State,
        statusLabel: String,
        statusSymbol: String,
        statusAccent: Color
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: statusSymbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(statusAccent)

            VStack(alignment: .leading, spacing: 1) {
                Text(profileName)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text(statusLabel)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }

    private func liveActivityStatusBadge(
        phase: VBridgeLiveActivityPhase,
        statusSymbol: String,
        statusAccent: Color
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: statusSymbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(statusAccent)

            Text(phase.displayTitle)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }

    private func liveActivityCompactNetworkRow(
        isp: String,
        ip: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "network")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.68))

                Text(isp)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)
            }

            HStack(spacing: 5) {
                Image(systemName: "location.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.68))

                Text(ip)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                    .minimumScaleFactor(0.52)
            }
        }
    }

    private func liveActivitySpeedRow(
        download: String,
        upload: String
    ) -> some View {
        HStack(spacing: 6) {
            liveActivitySpeedChip(
                title: "DL",
                value: download,
                systemImage: "arrow.down.circle.fill"
            )

            liveActivitySpeedChip(
                title: "UL",
                value: upload,
                systemImage: "arrow.up.circle.fill"
            )
        }
    }

    private func liveActivitySpeedChip(
        title: String,
        value: String,
        systemImage: String
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))

            Text(title)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.68))

            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 7)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func liveActivityExpandedBottomView(state: VBridgeVPNLiveActivityAttributes.ContentState) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "network")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))

                Text(state.ispText)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                Image(systemName: "location.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))

                Text(state.ipAddressText)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)

                Spacer(minLength: 0)
            }
        }
    }

    private func liveActivityTint(for phase: VBridgeLiveActivityPhase) -> Color {
        switch phase {
        case .connected:
            return .green
        case .connecting, .disconnecting:
            return .orange
        case .disconnected:
            return .red
        case .unknown:
            return .white.opacity(0.75)
        }
    }

    private func speedChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.66))
                .lineLimit(1)

            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct VBridgeWidget: Widget {
    let kind = "VBridgeWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WidgetProvider()) { entry in
            WidgetCardView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("VBridge")
        .description("Shows connection count, relay IP, and refreshes when you open it.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

@main
struct VBridgeWidgetBundle: WidgetBundle {
    var body: some Widget {
        VBridgeWidget()
        if #available(iOS 16.1, *) {
            VBridgeLiveActivityWidget()
        }
        if #available(iOS 18.0, *) {
            VBridgeConnectControlWidget()
        }
    }
}
