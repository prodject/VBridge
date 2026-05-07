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
        lastUpdated: .now
    )

    static func load() -> WidgetSnapshot {
        guard let logURL = logURL(),
              let content = try? String(contentsOf: logURL, encoding: .utf8) else {
            return WidgetSnapshot(state: .unknown, activeConnections: nil, totalConnections: nil, relayIP: nil, lastUpdated: .now)
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

        return WidgetSnapshot(
            state: state,
            activeConnections: activeConnections,
            totalConnections: totalConnections,
            relayIP: relayIP,
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

private struct WidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> WidgetEntry {
        WidgetEntry(date: .now, snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (WidgetEntry) -> Void) {
        completion(WidgetEntry(date: .now, snapshot: WidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        let snapshot = WidgetSnapshot.load()
        let refreshDate = Calendar.current.date(byAdding: .minute, value: snapshot.state == .connected ? 1 : 5, to: .now) ?? .now.addingTimeInterval(60)
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

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("VBridge")
                            .font(.system(size: family == .systemSmall ? 16 : 18, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                        Text(snapshot.statusLabel)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.75))
                    }

                    Spacer()

                    Image(systemName: snapshot.statusSymbol)
                        .font(.system(size: family == .systemSmall ? 24 : 28, weight: .semibold))
                        .foregroundStyle(snapshot.statusAccent)
                        .padding(10)
                        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(snapshot.connectionsText)
                            .font(.system(size: family == .systemSmall ? 32 : 34, weight: .black, design: .rounded))
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
                            .font(.system(size: family == .systemSmall ? 12 : 13, weight: .semibold, design: .monospaced))
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
        .widgetURL(snapshot.actionURL)
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
    }
}
