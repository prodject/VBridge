import Foundation
import WidgetKit
import SwiftUI

private enum WidgetAppGroup {
    static let identifier = "group.com.prodject.vbridge"
}

private struct WidgetSnapshot: Equatable {
    enum State: String {
        case connected
        case connecting
        case disconnected
        case unknown
    }

    let state: State
    let activeConnections: Int?
    let totalConnections: Int?
    let relayIP: String?
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

    var actionURL: URL {
        URL(string: "vbridge://refresh")!
    }

    static let placeholder = WidgetSnapshot(
        state: .connected,
        activeConnections: 6,
        totalConnections: 10,
        relayIP: "193.203.43.9",
        pings: PingSample.placeholderSamples,
        lastUpdated: .now
    )

    static func load() -> WidgetSnapshot {
        guard let logURL = logURL(),
              let content = try? String(contentsOf: logURL, encoding: .utf8) else {
            return WidgetSnapshot(
                state: .unknown,
                activeConnections: nil,
                totalConnections: nil,
                relayIP: nil,
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
                relayIP = value.split(separator: ":", maxSplits: 1).first.map(String.init)
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
            state: state,
            activeConnections: activeConnections,
            totalConnections: totalConnections,
            relayIP: relayIP,
            pings: pings,
            lastUpdated: .now
        )
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
        let refreshDate = Calendar.current.date(byAdding: .second, value: snapshot.state == .connected ? 30 : 300, to: .now) ?? .now.addingTimeInterval(60)
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
                    Color(red: 0.10, green: 0.24, blue: 0.46).opacity(0.52),
                    Color(red: 0.12, green: 0.42, blue: 0.58).opacity(0.42),
                    Color(red: 0.10, green: 0.50, blue: 0.56).opacity(0.34)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(snapshot.statusAccent.opacity(0.24))
                .frame(width: family == .systemSmall ? 110 : 140, height: family == .systemSmall ? 110 : 140)
                .blur(radius: 28)
                .offset(x: family == .systemSmall ? 56 : 86, y: family == .systemSmall ? -40 : -50)

            Circle()
                .fill(Color.white.opacity(0.10))
                .frame(width: family == .systemSmall ? 84 : 104, height: family == .systemSmall ? 84 : 104)
                .blur(radius: 24)
                .offset(x: family == .systemSmall ? -58 : -72, y: family == .systemSmall ? 44 : 56)

            content(snapshot: snapshot)
        }
        .widgetURL(snapshot.actionURL)
    }

    @ViewBuilder
    private func content(snapshot: WidgetSnapshot) -> some View {
        switch family {
        case .systemSmall:
            smallLayout(snapshot: snapshot)
        default:
            mediumLayout(snapshot: snapshot)
        }
    }

    private func prompt(for snapshot: WidgetSnapshot) -> String {
        "Tap to refresh"
    }

    private func smallLayout(snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("VBridge")
                        .font(.system(size: 14, weight: .black, design: .rounded))
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
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                Text("active connections")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.70))
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

            HStack {
                Text(prompt(for: snapshot))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.84))

                Spacer(minLength: 0)

                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.86))
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
    }

    private func mediumLayout(snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("VBridge")
                        .font(.system(size: 15, weight: .black, design: .rounded))
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
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)

                Text("active connections")
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

            HStack {
                Text(prompt(for: snapshot))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.84))

                Spacer(minLength: 0)

                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.86))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Ping")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
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
                    .font(.system(size: 9, weight: .black, design: .rounded))
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

private struct VBridgeWidget: Widget {
    let kind = "VBridgeWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WidgetProvider()) { entry in
            WidgetCardView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("VBridge")
        .description("Shows connection count, relay IP, and refreshes when you open it.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

@main
struct VBridgeWidgetBundle: WidgetBundle {
    var body: some Widget {
        VBridgeWidget()
        if #available(iOS 18.0, *) {
            VBridgeConnectControlWidget()
        }
    }
}
