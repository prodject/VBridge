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
        URL(string: "vbridge://toggle")!
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
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.12, blue: 0.22),
                    Color(red: 0.04, green: 0.24, blue: 0.36),
                    Color(red: 0.10, green: 0.46, blue: 0.52)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if family == .systemSmall {
                smallLayout(snapshot: snapshot)
            } else {
                mediumLayout(snapshot: snapshot)
            }
        }
        .widgetURL(snapshot.actionURL)
    }

    private func smallLayout(snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("VBridge")
                        .font(.system(size: 16, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    Text(snapshot.statusLabel)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                }

                Spacer()

                Image(systemName: snapshot.statusSymbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(snapshot.statusAccent)
                    .padding(10)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(snapshot.connectionsText)
                        .font(.system(size: 32, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    Text("connections")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                }

                HStack(spacing: 8) {
                    Image(systemName: "network")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    Text(snapshot.relayText)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }

            Spacer(minLength: 0)

            HStack {
                Text(snapshot.state == .connected || snapshot.state == .connecting ? "Tap to disconnect" : "Tap to connect")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))

                Spacer()

                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(16)
    }

    private func mediumLayout(snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("VBridge")
                        .font(.system(size: 20, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    Text(snapshot.statusLabel)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                }

                Spacer()

                Image(systemName: snapshot.statusSymbol)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(snapshot.statusAccent)
                    .padding(10)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(snapshot.connectionsText)
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                Text("connections")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(snapshot.relayText)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            VStack(spacing: 10) {
                ForEach(snapshot.pings, id: \.name) { ping in
                    PingRowView(sample: ping)
                }
            }

            Spacer(minLength: 0)

            HStack {
                Text("Live pings every 30s")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))

                Spacer()

                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(16)
    }
}

private struct PingRowView: View {
    let sample: PingSample

    var body: some View {
        HStack(spacing: 10) {
            Text(sample.name)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 88, alignment: .leading)

            HStack(spacing: 4) {
                ForEach(0..<5, id: \.self) { index in
                    Circle()
                        .fill(index < sample.dotCount ? sample.dotColor : .white.opacity(0.18))
                        .frame(width: 6, height: 6)
                }
            }

            Spacer()

            Text(sample.latencyText)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct VBridgeWidget: Widget {
    let kind = "VBridgeWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WidgetProvider()) { entry in
            if #available(iOSApplicationExtension 17.0, *) {
                WidgetCardView(entry: entry)
                    .containerBackground(.clear, for: .widget)
            } else {
                WidgetCardView(entry: entry)
            }
        }
        .configurationDisplayName("VBridge")
        .description("Shows connection count, relay IP, and opens the app to toggle the tunnel.")
        .supportedFamilies([.systemSmall, .systemMedium])
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
