import ActivityKit
import Foundation

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
    }

    var profileName: String
}

@available(iOS 16.1, *)
struct VBridgeLiveActivitySnapshot: Codable, Hashable {
    var profileName: String
    var content: VBridgeVPNLiveActivityAttributes.ContentState
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
    }

    static func update(
        profileName: String? = nil,
        phase: VBridgeLiveActivityPhase? = nil,
        activeConnections: Int? = nil,
        totalConnections: Int? = nil,
        relayIP: String? = nil,
        estimatedRemainingSeconds: Int? = nil,
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
            } else if phase == .disconnected || phase == .unknown {
                snapshot.content.activeConnections = nil
                snapshot.content.totalConnections = nil
                snapshot.content.relayIP = nil
                snapshot.content.estimatedRemainingSeconds = nil
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
        snapshot.content.updatedAt = updatedAt
        save(snapshot)
    }

    static func clear() {
        defaults?.removeObject(forKey: snapshotKey)
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
        estimatedRemainingSeconds: Int? = nil
    ) {
        let updatedAt = Date()
        let snapshot = VBridgeLiveActivitySnapshot(
            profileName: profileName,
            content: .init(
                phase: phase,
                activeConnections: activeConnections,
                totalConnections: totalConnections,
                relayIP: relayIP,
                estimatedRemainingSeconds: estimatedRemainingSeconds,
                updatedAt: updatedAt
            )
        )
        VBridgeLiveActivityStore.save(snapshot)

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
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

        if let currentActivity, currentActivity.attributes.profileName == snapshot.profileName {
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

        if let currentActivity, currentActivity.attributes.profileName == snapshot.profileName {
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
