#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
import Foundation
import CoreFoundation
#if canImport(WidgetKit)
import WidgetKit
#endif

private enum LiveActivitySharedStore {
    static let defaultAppGroupID = "group.com.prodject.vbridge"

    static func appGroupID() -> String? {
        let candidates = [
            defaultAppGroupID,
            derivedAppGroupID()
        ].compactMap { $0 }

        for candidate in candidates {
            if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: candidate) != nil {
                return candidate
            }
        }
        return nil
    }

    private static func derivedAppGroupID() -> String? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let baseBundleID = bundleID.replacingOccurrences(of: ".network-extension", with: "")
        return "group.\(baseBundleID)"
    }
}

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
        var trustedWiFiActive: Bool? = nil
        var bypassEnabled: Bool? = nil
        var connectedSince: Date? = nil
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
        guard let groupID = LiveActivitySharedStore.appGroupID() else { return nil }
        return UserDefaults(suiteName: groupID)
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

    private static var defaults: UserDefaults {
        if let groupID = LiveActivitySharedStore.appGroupID(),
           let sharedDefaults = UserDefaults(suiteName: groupID) {
            return sharedDefaults
        }
        return .standard
    }

    static func load() -> VBridgeLiveActivitySnapshot? {
        guard let data = defaults.data(forKey: snapshotKey) else { return nil }
        return try? decoder.decode(VBridgeLiveActivitySnapshot.self, from: data)
    }

    static func save(_ incoming: VBridgeLiveActivitySnapshot) {
        var snapshot = incoming
        let previous = load()
        if snapshot.content.phase.isActiveSession {
            snapshot.content.bypassEnabled = snapshot.content.bypassEnabled ?? previous?.content.bypassEnabled
            snapshot.content.trustedWiFiActive = snapshot.content.trustedWiFiActive ?? previous?.content.trustedWiFiActive
            if snapshot.content.phase == .connected {
                snapshot.content.connectedSince = snapshot.content.connectedSince
                    ?? (previous?.profileName == snapshot.profileName ? previous?.content.connectedSince : nil)
                    ?? .now
            } else {
                snapshot.content.connectedSince = nil
            }
        } else {
            snapshot.content.bypassEnabled = false
            snapshot.content.trustedWiFiActive = false
            snapshot.content.connectedSince = nil
        }
        guard let data = try? encoder.encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
        defaults.synchronize()
        if LiveActivitySharedStore.appGroupID() != nil {
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
        }
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
        bypassEnabled: Bool? = nil,
        trustedWiFiActive: Bool? = nil,
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
        if let bypassEnabled { snapshot.content.bypassEnabled = bypassEnabled }
        if let trustedWiFiActive { snapshot.content.trustedWiFiActive = trustedWiFiActive }
        snapshot.content.updatedAt = updatedAt
        save(snapshot)
        if bypassEnabled != nil || trustedWiFiActive != nil {
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName(rawValue: "com.prodject.vbridge.live-routing.changed" as CFString),
                nil, nil, true
            )
        }
    }

    static func clear() {
        defaults.removeObject(forKey: snapshotKey)
        defaults.synchronize()
        if LiveActivitySharedStore.appGroupID() != nil {
            VBridgeWidgetSnapshotStore.clear()
        }
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
    private var revision = 0

    private init() {
        activity = Activity<VBridgeVPNLiveActivityAttributes>.activities.first
        // A shared-defaults write alone does not update ActivityKit. Notify the
        // app while it is running; iOS may defer this while the app is suspended.
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), nil,
            { _, _, _, _, _ in
                Task { @MainActor in
                    VBridgeLiveActivityCoordinator.shared.refreshRoutingState()
                }
            },
            "com.prodject.vbridge.live-routing.changed" as CFString,
            nil, .deliverImmediately
        )
    }

    private func refreshRoutingState() {
        guard let snapshot = VBridgeLiveActivityStore.load(),
              snapshot.content.phase.isActiveSession else { return }
        revision += 1
        let currentRevision = revision
        Task { @MainActor in
            guard self.revision == currentRevision else { return }
            await self.apply(snapshot: snapshot)
        }
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
        if phase == .disconnected {
            end(profileName: profileName)
            return
        }
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

        if let existing = VBridgeLiveActivityStore.load(), existing.profileName == profileName,
           phase != .connecting || existing.content.phase == .connecting {
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

        if phase == .disconnecting || phase == .disconnected || phase == .unknown {
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

        if phase == .connecting {
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

        // Activity.request must happen before the app leaves the foreground.
        // Do not defer creation to a Task after asynchronous VPN bootstrap.
        let published = VBridgeLiveActivityStore.load() ?? snapshot
        revision += 1
        let currentRevision = revision
        if let current = activity,
           current.activityState == .ended || current.activityState == .dismissed {
            activity = nil
        }
        if activity?.attributes.profileName != profileName {
            let previous = activity
            activity = Activity<VBridgeVPNLiveActivityAttributes>.activities.first {
                $0.attributes.profileName == profileName && ($0.activityState == .active || $0.activityState == .stale)
            }
            if let previous, previous.id != activity?.id {
                Task { await previous.end(nil, dismissalPolicy: .immediate) }
            }
        }
        if activity == nil, phase == .connecting || phase == .connected {
            do {
                activity = try Activity.request(
                    attributes: VBridgeVPNLiveActivityAttributes(profileName: profileName),
                    content: ActivityContent(state: published.content, staleDate: Date().addingTimeInterval(120)),
                    pushType: nil
                )
            } catch {
                NSLog("Failed to start Live Activity: \(error.localizedDescription)")
            }
        }
        Task { @MainActor in
            guard self.revision == currentRevision else { return }
            await self.apply(snapshot: published)
        }
    }

    func end(
        profileName: String,
        finalPhase: VBridgeLiveActivityPhase = .disconnected,
        immediate: Bool = true
    ) {
        revision += 1
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

        // Capture the old session now so a delayed end cannot remove a newly
        // created activity for the same profile after a reconnect.
        let activities = Activity<VBridgeVPNLiveActivityAttributes>.activities.filter {
            $0.attributes.profileName == profileName
        }
        if activity?.attributes.profileName == profileName { activity = nil }
        Task { @MainActor in
            await self.endActivity(snapshot: snapshot, immediate: immediate, activities: activities)
        }
    }

    private func apply(snapshot: VBridgeLiveActivitySnapshot) async {
        let content = ActivityContent(
            state: snapshot.content,
            staleDate: Date().addingTimeInterval(120),
            relevanceScore: snapshot.content.phase == .connecting ? 1.0 : 0.75
        )

        if let currentActivity = activity, currentActivity.attributes.profileName == snapshot.profileName {
            await currentActivity.update(content)
            return
        }

        // Creation is synchronous in sync(); an outdated update must never
        // create another activity after end() has already run.
    }

    private func endActivity(snapshot: VBridgeLiveActivitySnapshot, immediate: Bool,
                             activities: [Activity<VBridgeVPNLiveActivityAttributes>]) async {
        let content = ActivityContent(
            state: snapshot.content,
            staleDate: nil,
            relevanceScore: 0.0
        )
        let dismissalPolicy: ActivityUIDismissalPolicy = immediate ? .immediate : .default

        for ongoingActivity in activities {
            await ongoingActivity.end(content, dismissalPolicy: dismissalPolicy)
        }
    }
}
#else
import Foundation

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

struct VBridgeVPNLiveActivityAttributes {
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
        var trustedWiFiActive: Bool? = nil
        var bypassEnabled: Bool? = nil
        var connectedSince: Date? = nil
        var updatedAt: Date

        var progressText: String? {
            guard let activeConnections, let totalConnections else {
                return nil
            }
            return "\(activeConnections)/\(totalConnections)"
        }
    }

    var profileName: String
}

struct VBridgeLiveActivitySnapshot: Codable, Hashable {
    var profileName: String
    var content: VBridgeVPNLiveActivityAttributes.ContentState
}

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

enum VBridgeWidgetSnapshotStore {
    static func load() -> VBridgeWidgetSnapshot? { nil }
    static func save(_ snapshot: VBridgeWidgetSnapshot) {}
    static func clear() {}
}

enum VBridgeLiveActivityStore {
    static func load() -> VBridgeLiveActivitySnapshot? { nil }
    static func save(_ snapshot: VBridgeLiveActivitySnapshot) {}
    static func clear() {}

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
        bypassEnabled: Bool? = nil,
        trustedWiFiActive: Bool? = nil,
        updatedAt: Date = .now
    ) {}
}

@MainActor
final class VBridgeLiveActivityCoordinator {
    static let shared = VBridgeLiveActivityCoordinator()

    private init() {}

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
    ) {}

    func end(
        profileName: String,
        finalPhase: VBridgeLiveActivityPhase = .disconnected,
        immediate: Bool = true
    ) {}
}
#endif
