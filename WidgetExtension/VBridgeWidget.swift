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
        pings: [PingSample],
        lastUpdated: Date
    ) {
        self.profileName = profileName
        self.state = state
        self.activeConnections = activeConnections
        self.totalConnections = totalConnections
        self.relayIP = relayIP
        self.estimatedRemainingSeconds = estimatedRemainingSeconds
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
        pings: PingSample.placeholderSamples,
        lastUpdated: .now
    )

    static func load() -> WidgetSnapshot {
        if let liveState = VBridgeLiveActivityStore.load() {
            return WidgetSnapshot(liveSnapshot: liveState)
        }

        guard let logURL = logURL(),
              let content = try? String(contentsOf: logURL, encoding: .utf8) else {
            return WidgetSnapshot(
                profileName: "VBridge",
                state: .unknown,
                activeConnections: nil,
                totalConnections: nil,
                relayIP: nil,
                estimatedRemainingSeconds: nil,
                pings: PingSample.placeholderSamples,
                lastUpdated: .now
            )
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
            pings: pings,
            lastUpdated: .now
        )
    }

    init(liveSnapshot: VBridgeLiveActivitySnapshot) {
        let state = State(rawValue: liveSnapshot.content.phase.rawValue) ?? .unknown
        self.profileName = liveSnapshot.profileName
        self.state = state
        self.activeConnections = liveSnapshot.content.activeConnections
        self.totalConnections = liveSnapshot.content.totalConnections
        self.relayIP = liveSnapshot.content.relayIP
        self.estimatedRemainingSeconds = liveSnapshot.content.estimatedRemainingSeconds
        self.pings = state == .connected ? PingSample.loadAll() : PingSample.placeholderSamples
        self.lastUpdated = liveSnapshot.content.updatedAt
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
            Rectangle()
                .fill(.ultraThinMaterial)

            LinearGradient(
                colors: [
                    Color(red: 0.07, green: 0.76, blue: 0.91).opacity(0.98),
                    Color(red: 0.77, green: 0.44, blue: 0.93).opacity(0.98),
                    Color(red: 0.96, green: 0.31, blue: 0.35).opacity(0.98)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color(red: 0.95, green: 0.95, blue: 0.97).opacity(0.28))
                .frame(width: family == .systemSmall ? 124 : 160, height: family == .systemSmall ? 124 : 160)
                .blur(radius: 36)
                .offset(x: family == .systemSmall ? -60 : -82, y: family == .systemSmall ? -50 : -66)

            Circle()
                .fill(Color(red: 0.48, green: 0.31, blue: 0.98).opacity(0.34))
                .frame(width: family == .systemSmall ? 132 : 168, height: family == .systemSmall ? 132 : 168)
                .blur(radius: 30)
                .offset(x: family == .systemSmall ? 58 : 82, y: family == .systemSmall ? 52 : 72)

            Circle()
                .fill(Color(red: 0.38, green: 0.50, blue: 0.98).opacity(0.18))
                .frame(width: family == .systemSmall ? 96 : 126, height: family == .systemSmall ? 96 : 126)
                .blur(radius: 24)
                .offset(x: family == .systemSmall ? 18 : 28, y: family == .systemSmall ? 18 : 24)

            content(snapshot: snapshot)
        }
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
                        .font(.system(size: 14, weight: .bold, design: .default))
                        .foregroundStyle(.white)
                    Text(snapshot.statusLabel)
                        .font(.system(size: 10, weight: .semibold, design: .default))
                        .foregroundStyle(.white.opacity(0.72))
                }

                Spacer(minLength: 0)

                Image(systemName: snapshot.statusSymbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(snapshot.statusAccent)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.connectionsText)
                    .font(.system(size: 24, weight: .bold, design: .default))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                Text(snapshot.summaryText)
                    .font(.system(size: 10, weight: .semibold, design: .default))
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

            Spacer(minLength: 0)

            refreshRow()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
    }

    private func mediumLayout(snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.profileName)
                        .font(.system(size: 15, weight: .bold, design: .default))
                        .foregroundStyle(.white)
                    Text(snapshot.statusLabel)
                        .font(.system(size: 10, weight: .semibold, design: .default))
                        .foregroundStyle(.white.opacity(0.72))
                }

                Spacer(minLength: 0)

                Image(systemName: snapshot.statusSymbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(snapshot.statusAccent)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(snapshot.connectionsText)
                    .font(.system(size: 24, weight: .bold, design: .default))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)

                Text(snapshot.summaryText)
                    .font(.system(size: 10, weight: .semibold, design: .default))
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
                    .font(.system(size: 10, weight: .semibold, design: .default))
                    .foregroundStyle(.white.opacity(0.78))
            }

            refreshRow()

            VStack(alignment: .leading, spacing: 6) {
                Text("Ping")
                    .font(.system(size: 10, weight: .semibold, design: .default))
                    .foregroundStyle(.white.opacity(0.75))

                HStack(alignment: .top, spacing: 6) {
                    ForEach(snapshot.pings, id: \.name) { ping in
                        PingCompactView(sample: ping)
                    }
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
    }

    private func largeLayout(snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.profileName)
                        .font(.system(size: 15, weight: .bold, design: .default))
                        .foregroundStyle(.white)
                    Text(snapshot.statusLabel)
                        .font(.system(size: 10, weight: .semibold, design: .default))
                        .foregroundStyle(.white.opacity(0.72))
                }

                Spacer(minLength: 0)

                Image(systemName: snapshot.statusSymbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(snapshot.statusAccent)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(snapshot.connectionsText)
                    .font(.system(size: 24, weight: .bold, design: .default))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)

                Text(snapshot.summaryText)
                    .font(.system(size: 10, weight: .semibold, design: .default))
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
                    .font(.system(size: 10, weight: .semibold, design: .default))
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

            VStack(alignment: .leading, spacing: 6) {
                Text("Ping")
                    .font(.system(size: 10, weight: .semibold, design: .default))
                    .foregroundStyle(.white.opacity(0.75))

                HStack(alignment: .top, spacing: 6) {
                    ForEach(snapshot.pings, id: \.name) { ping in
                        PingCompactView(sample: ping)
                    }
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func refreshRow() -> some View {
        if #available(iOS 17.0, *) {
            Button(intent: RefreshVBridgeWidgetIntent()) {
                HStack {
                    Text("Tap to refresh")
                        .font(.system(size: 10, weight: .semibold, design: .default))
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
                    .font(.system(size: 10, weight: .semibold, design: .default))
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
                .font(.system(size: 10, weight: .semibold, design: .default))
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
                    .font(.system(size: 9, weight: .bold, design: .default))
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
            liveActivityLockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.92))
                .activitySystemActionForegroundColor(.white)
                .padding(.vertical, 4)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    liveActivityHeader(state: context.state)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(context.state.phase.displayTitle)
                            .font(.system(size: 12, weight: .semibold, design: .default))
                            .foregroundStyle(.white.opacity(0.86))

                        Text(context.state.remainingText ?? context.state.progressText ?? "VPN")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    liveActivityExpandedBottomView(state: context.state)
                }
            } compactLeading: {
                Image(systemName: context.state.phase == .connected ? "lock.shield.fill" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(liveActivityTint(for: context.state.phase))
            } compactTrailing: {
                Text(context.state.remainingText ?? context.state.progressText ?? context.state.phase.displayTitle)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
            } minimal: {
                Image(systemName: context.state.phase == .connected ? "lock.shield.fill" : "wifi")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(liveActivityTint(for: context.state.phase))
            }
            .keylineTint(liveActivityTint(for: context.state.phase))
        }
    }

    private func liveActivityLockScreenView(state: VBridgeVPNLiveActivityAttributes.ContentState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            liveActivityHeader(state: state)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(state.progressText ?? "0/0")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 2) {
                    Text(state.phase.displayTitle)
                        .font(.system(size: 12, weight: .semibold, design: .default))
                        .foregroundStyle(.white.opacity(0.82))

                    Text(state.remainingText ?? state.relayText)
                        .font(.system(size: 12, weight: .semibold, design: .default))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }
            }

            ProgressView(value: state.progressFraction ?? 0)
                .tint(liveActivityTint(for: state.phase))
                .progressViewStyle(.linear)

            HStack(spacing: 6) {
                Image(systemName: "network")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Text(state.relayText)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func liveActivityHeader(state: VBridgeVPNLiveActivityAttributes.ContentState) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: state.phase == .connected ? "lock.shield.fill" : "arrow.triangle.2.circlepath")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(liveActivityTint(for: state.phase))

            VStack(alignment: .leading, spacing: 2) {
                Text("VBridge")
                    .font(.system(size: 13, weight: .bold, design: .default))
                    .foregroundStyle(.white)
                Text(state.phase.displayTitle)
                    .font(.system(size: 10, weight: .semibold, design: .default))
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
    }

    private func liveActivityExpandedBottomView(state: VBridgeVPNLiveActivityAttributes.ContentState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: state.progressFraction ?? 0)
                .tint(liveActivityTint(for: state.phase))
                .progressViewStyle(.linear)

            HStack(alignment: .center, spacing: 10) {
                Text(state.progressText ?? "0/0")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)

                Spacer(minLength: 0)

                Text(state.remainingText ?? state.phase.displayTitle)
                    .font(.system(size: 12, weight: .semibold, design: .default))
                    .foregroundStyle(.white.opacity(0.78))
            }
        }
        .padding(.top, 2)
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
