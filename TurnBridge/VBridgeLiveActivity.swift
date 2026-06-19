import ActivityKit
import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

@available(iOS 16.1, *)
struct VBridgePingSample: Codable, Hashable {
    var name: String
    var latencyMs: Int?

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
}

@available(iOS 16.1, *)
enum VBridgeLiveActivityPhase: String, Codable, Hashable {
    case connecting
    case connected
    case disconnecting
    case disconnected
    case unknown

    var displayTitle: String {
        switch self {
        case .connecting:
            return "Connecting"
        case .connected:
            return "Connected"
        case .disconnecting:
            return "Disconnecting"
        case .disconnected:
            return "Disconnected"
        case .unknown:
            return "Unknown"
        }
    }

    var isActiveSession: Bool {
        switch self {
        case .connecting, .connected, .disconnecting:
            return true
        case .disconnected, .unknown:
            return false
        }
    }
}

@available(iOS 16.1, *)
struct VBridgeVPNLiveActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: VBridgeLiveActivityPhase
        var activeConnections: Int?
        var totalConnections: Int?
        var relayIP: String?
        var estimatedRemainingSeconds: Int?
        var downloadSpeedMbps: Double?
        var uploadSpeedMbps: Double?
        var ispName: String?
        var ipAddress: String?
        var pingSamples: [VBridgePingSample]?
        var updatedAt: Date

        var progressFraction: Double? {
            guard let activeConnections, let totalConnections, totalConnections > 0 else {
                return nil
            }
            return min(max(Double(activeConnections) / Double(totalConnections), 0), 1)
        }

        var progressText: String? {
            guard let activeConnections, let totalConnections else {
                return nil
            }
            return "\(activeConnections)/\(totalConnections)"
        }

        var relayText: String {
            relayIP ?? "No relay IP"
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

        var downloadSpeedText: String? {
            speedText(downloadSpeedMbps, fallback: "DL --")
        }

        var uploadSpeedText: String? {
            speedText(uploadSpeedMbps, fallback: "UL --")
        }

        var speedSummaryText: String {
            let download = downloadSpeedText ?? "DL --"
            let upload = uploadSpeedText ?? "UL --"
            return "\(download)  •  \(upload)"
        }

        var ispText: String {
            ispName ?? "ISP --"
        }

        var ipAddressText: String {
            ipAddress ?? "IP --"
        }

        private func speedText(_ value: Double?, fallback: String) -> String? {
            guard let value, value.isFinite else { return fallback }
            let clampedValue = max(value, 0)
            return String(format: "%.1f Mbps", clampedValue)
        }
    }

    var profileName: String
}

@available(iOS 16.1, *)
struct VBridgeLiveActivitySnapshot: Codable, Hashable {
    var profileName: String
    var content: VBridgeVPNLiveActivityAttributes.ContentState
}

@available(iOS 16.1, *)
struct VBridgeWidgetSnapshot: Codable, Hashable {
    var profileName: String
    var phase: VBridgeLiveActivityPhase
    var activeConnections: Int?
    var totalConnections: Int?
    var relayIP: String?
    var estimatedRemainingSeconds: Int?
    var downloadSpeedMbps: Double?
    var uploadSpeedMbps: Double?
    var ispName: String?
    var ipAddress: String?
    var pingSamples: [VBridgePingSample]?
    var updatedAt: Date
}

@available(iOS 16.1, *)
enum VBridgeWidgetSnapshotStore {
    private static let appGroupID = "group.com.prodject.vbridge"
    private static let snapshotKey = "vbridge.widget.snapshot"

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    static func load() -> VBridgeWidgetSnapshot? {
        guard let data = defaults?.data(forKey: snapshotKey) else { return nil }
        return try? decoder.decode(VBridgeWidgetSnapshot.self, from: data)
    }

    static func save(_ snapshot: VBridgeWidgetSnapshot) {
        guard let defaults,
              let data = try? encoder.encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
        defaults.synchronize()
        reloadWidgetTimelinesIfAvailable()
    }

    static func clear() {
        defaults?.removeObject(forKey: snapshotKey)
        defaults?.synchronize()
        reloadWidgetTimelinesIfAvailable()
    }

    private static func reloadWidgetTimelinesIfAvailable() {
#if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: "VBridgeWidget")
#endif
    }
}

@available(iOS 16.1, *)
enum VBridgeLiveActivityStore {
    private static let appGroupID = "group.com.prodject.vbridge"
    private static let snapshotKey = "vbridge.live.activity.snapshot"

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    static func load() -> VBridgeLiveActivitySnapshot? {
        guard let data = defaults?.data(forKey: snapshotKey) else { return nil }
        return try? decoder.decode(VBridgeLiveActivitySnapshot.self, from: data)
    }

    static func save(_ snapshot: VBridgeLiveActivitySnapshot) {
        guard let defaults else { return }
        guard let data = try? encoder.encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
        defaults.synchronize()
        VBridgeWidgetSnapshotStore.save(
            VBridgeWidgetSnapshot(
                profileName: snapshot.profileName,
                phase: snapshot.content.phase,
                activeConnections: snapshot.content.activeConnections,
                totalConnections: snapshot.content.totalConnections,
                relayIP: snapshot.content.relayIP,
                estimatedRemainingSeconds: snapshot.content.estimatedRemainingSeconds,
                downloadSpeedMbps: snapshot.content.downloadSpeedMbps,
                uploadSpeedMbps: snapshot.content.uploadSpeedMbps,
                ispName: snapshot.content.ispName,
                ipAddress: snapshot.content.ipAddress,
                pingSamples: snapshot.content.pingSamples,
                updatedAt: snapshot.content.updatedAt
            )
        )
        reloadWidgetTimelinesIfAvailable()
    }

    static func update(
        profileName: String? = nil,
        phase: VBridgeLiveActivityPhase? = nil,
        activeConnections: Int? = nil,
        totalConnections: Int? = nil,
        relayIP: String? = nil,
        estimatedRemainingSeconds: Int? = nil,
        downloadSpeedMbps: Double? = nil,
        uploadSpeedMbps: Double? = nil,
        ispName: String? = nil,
        ipAddress: String? = nil,
        pingSamples: [VBridgePingSample]? = nil,
        updatedAt: Date = .now
    ) {
        var snapshot = load() ?? VBridgeLiveActivitySnapshot(
            profileName: profileName ?? "VBridge",
            content: .init(
                phase: phase ?? .unknown,
                activeConnections: nil,
                totalConnections: nil,
                relayIP: nil,
                estimatedRemainingSeconds: nil,
                downloadSpeedMbps: nil,
                uploadSpeedMbps: nil,
                ispName: nil,
                ipAddress: nil,
                pingSamples: nil,
                updatedAt: updatedAt
            )
        )

        if let profileName {
            snapshot.profileName = profileName
        }
        if let phase {
            snapshot.content.phase = phase
            if phase == .connecting || phase == .disconnecting {
                snapshot.content.activeConnections = nil
                snapshot.content.totalConnections = nil
                snapshot.content.relayIP = nil
                snapshot.content.estimatedRemainingSeconds = nil
                snapshot.content.downloadSpeedMbps = nil
                snapshot.content.uploadSpeedMbps = nil
                snapshot.content.ispName = nil
                snapshot.content.ipAddress = nil
                snapshot.content.pingSamples = nil
            } else if phase == .disconnected || phase == .unknown {
                snapshot.content.activeConnections = nil
                snapshot.content.totalConnections = nil
                snapshot.content.relayIP = nil
                snapshot.content.estimatedRemainingSeconds = nil
                snapshot.content.downloadSpeedMbps = nil
                snapshot.content.uploadSpeedMbps = nil
                snapshot.content.ispName = nil
                snapshot.content.ipAddress = nil
                snapshot.content.pingSamples = nil
            }
        }
        if let activeConnections {
            snapshot.content.activeConnections = activeConnections
        }
        if let totalConnections {
            snapshot.content.totalConnections = totalConnections
        }
        if let relayIP {
            snapshot.content.relayIP = relayIP
        }
        if let estimatedRemainingSeconds {
            snapshot.content.estimatedRemainingSeconds = estimatedRemainingSeconds
        }
        if let downloadSpeedMbps {
            snapshot.content.downloadSpeedMbps = downloadSpeedMbps
        }
        if let uploadSpeedMbps {
            snapshot.content.uploadSpeedMbps = uploadSpeedMbps
        }
        if let ispName {
            snapshot.content.ispName = ispName
        }
        if let ipAddress {
            snapshot.content.ipAddress = ipAddress
        }
        if let pingSamples {
            snapshot.content.pingSamples = pingSamples
        }
        snapshot.content.updatedAt = updatedAt
        save(snapshot)
    }

    static func clear() {
        defaults?.removeObject(forKey: snapshotKey)
        defaults?.synchronize()
        VBridgeWidgetSnapshotStore.clear()
    }

    private static func reloadWidgetTimelinesIfAvailable() {
#if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: "VBridgeWidget")
#endif
    }
}

@available(iOS 16.1, *)
@MainActor
final class VBridgeLiveActivityCoordinator {
    static let shared = VBridgeLiveActivityCoordinator()

    private var activity: Activity<VBridgeVPNLiveActivityAttributes>?

    private init() {
        activity = Activity<VBridgeVPNLiveActivityAttributes>.activities.first
    }

    func sync(
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
        let updatedAt = Date()
        var content = VBridgeVPNLiveActivityAttributes.ContentState(
            phase: phase,
            activeConnections: activeConnections,
            totalConnections: totalConnections,
            relayIP: relayIP,
            estimatedRemainingSeconds: estimatedRemainingSeconds,
            downloadSpeedMbps: downloadSpeedMbps,
            uploadSpeedMbps: uploadSpeedMbps,
            ispName: ispName,
            ipAddress: ipAddress,
            pingSamples: pingSamples,
            updatedAt: updatedAt
        )

        if let existing = VBridgeLiveActivityStore.load(), existing.profileName == profileName {
            if content.activeConnections == nil {
                content.activeConnections = existing.content.activeConnections
            }
            if content.totalConnections == nil {
                content.totalConnections = existing.content.totalConnections
            }
            if content.relayIP == nil {
                content.relayIP = existing.content.relayIP
            }
            if content.estimatedRemainingSeconds == nil {
                content.estimatedRemainingSeconds = existing.content.estimatedRemainingSeconds
            }
            if content.downloadSpeedMbps == nil {
                content.downloadSpeedMbps = existing.content.downloadSpeedMbps
            }
            if content.uploadSpeedMbps == nil {
                content.uploadSpeedMbps = existing.content.uploadSpeedMbps
            }
            if content.ispName == nil {
                content.ispName = existing.content.ispName
            }
            if content.ipAddress == nil {
                content.ipAddress = existing.content.ipAddress
            }
            if content.pingSamples == nil {
                content.pingSamples = existing.content.pingSamples
            }
        }

        if phase == .connecting || phase == .disconnecting || phase == .disconnected || phase == .unknown {
            content.activeConnections = nil
            content.totalConnections = nil
            content.relayIP = nil
            content.estimatedRemainingSeconds = nil
            content.downloadSpeedMbps = nil
            content.uploadSpeedMbps = nil
            content.ispName = nil
            content.ipAddress = nil
            content.pingSamples = nil
        }

        let snapshot = VBridgeLiveActivitySnapshot(profileName: profileName, content: content)
        VBridgeLiveActivityStore.save(snapshot)

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            NSLog("Live Activity not started: activities are disabled")
            return
        }

        Task { @MainActor in
            await self.apply(snapshot: snapshot)
        }
    }

    func end(
        profileName: String,
        finalPhase: VBridgeLiveActivityPhase = .disconnected,
        immediate: Bool = true
    ) {
        let updatedAt = Date()
        let snapshot = VBridgeLiveActivitySnapshot(
            profileName: profileName,
            content: .init(
                phase: finalPhase,
                activeConnections: nil,
                totalConnections: nil,
                relayIP: nil,
                estimatedRemainingSeconds: nil,
                downloadSpeedMbps: nil,
                uploadSpeedMbps: nil,
                ispName: nil,
                ipAddress: nil,
                pingSamples: nil,
                updatedAt: updatedAt
            )
        )
        VBridgeLiveActivityStore.save(snapshot)

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return
        }

        Task { @MainActor in
            await self.endActivity(snapshot: snapshot, immediate: immediate)
        }
    }

    private func apply(snapshot: VBridgeLiveActivitySnapshot) async {
        let content = ActivityContent(
            state: snapshot.content,
            staleDate: snapshot.content.phase == .connecting ? Date().addingTimeInterval(45) : nil,
            relevanceScore: snapshot.content.phase == .connecting ? 1.0 : 0.75
        )

        if let currentActivity = activity, currentActivity.attributes.profileName == snapshot.profileName {
            await currentActivity.update(content)
            if snapshot.content.phase == .disconnected {
                await currentActivity.end(content, dismissalPolicy: .immediate)
                activity = nil
            }
            return
        }

        if snapshot.content.phase == .disconnected {
            activity = nil
            return
        }

        do {
            let requested = try Activity.request(
                attributes: VBridgeVPNLiveActivityAttributes(profileName: snapshot.profileName),
                content: content,
                pushType: nil
            )
            activity = requested
        } catch {
            activity = nil
            NSLog("Failed to start Live Activity: \(error.localizedDescription)")
        }
    }

    private func endActivity(snapshot: VBridgeLiveActivitySnapshot, immediate: Bool) async {
        let content = ActivityContent(
            state: snapshot.content,
            staleDate: nil,
            relevanceScore: 0.0
        )
        let dismissalPolicy: ActivityUIDismissalPolicy = immediate ? .immediate : .default

        if let currentActivity = activity, currentActivity.attributes.profileName == snapshot.profileName {
            await currentActivity.end(content, dismissalPolicy: dismissalPolicy)
            activity = nil
            return
        }

        for ongoingActivity in Activity<VBridgeVPNLiveActivityAttributes>.activities {
            if ongoingActivity.attributes.profileName == snapshot.profileName {
                await ongoingActivity.end(content, dismissalPolicy: dismissalPolicy)
            }
        }
        activity = nil
    }
}
