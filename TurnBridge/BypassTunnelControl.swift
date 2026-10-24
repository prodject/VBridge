import Foundation
import NetworkExtension
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif

/// The preference is separate from the extension-confirmed state in ContentState.
enum BypassTunnelPreference {
    static let key = "bypassVPNTunnel"
    static var defaults: UserDefaults {
        if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.prodject.vbridge") != nil,
           let shared = UserDefaults(suiteName: "group.com.prodject.vbridge") {
            return shared
        }
        return .standard
    }
    static var enabled: Bool { defaults.bool(forKey: key) }
}

@MainActor
enum BypassTunnelControl {
    private static var busy = false

    static func disconnect() async throws {
        guard let manager = try await currentManager() else { throw failure("The VPN profile is unavailable.") }
        manager.connection.stopVPNTunnel()
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        if #available(iOS 16.2, *), var snapshot = VBridgeLiveActivityStore.load() {
            snapshot.content.phase = .disconnecting
            snapshot.content.connectedSince = nil
            snapshot.content.updatedAt = .now
            VBridgeLiveActivityStore.save(snapshot)
            for activity in Activity<VBridgeVPNLiveActivityAttributes>.activities {
                await activity.end(ActivityContent(state: snapshot.content, staleDate: .now), dismissalPolicy: .immediate)
            }
        }
#endif
    }

    static func setEnabled(_ enabled: Bool) async throws {
        guard !busy else { throw failure("A routing change is already in progress.") }
        busy = true
        defer { busy = false }

        let manager = try await currentManager()
        try await apply(enabled, manager: manager)
    }

    private static func currentManager() async throws -> NETunnelProviderManager? {

        // Both the app and widget contain this type. LiveActivityIntent runs in
        // the app, where the embedded appex gives the actual (possibly re-signed) ID.
        let plugins = Bundle.main.builtInPlugInsURL
        let bundles = plugins.flatMap { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) } ?? []
        let providerID = bundles.compactMap { Bundle(url: $0) }.first {
            ($0.infoDictionary?["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String == "com.apple.networkextension.packet-tunnel"
        }?.bundleIdentifier
        guard let providerID else { throw failure("The VPN extension is unavailable.") }
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        return managers.first {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerID
        }
    }

    private static func apply(_ enabled: Bool, manager: NETunnelProviderManager?) async throws {
        var confirmedConnected = false
        if let manager {
            switch manager.connection.status {
            case .connected:
                guard (manager.protocolConfiguration as? NETunnelProviderProtocol)?.includeAllNetworks == false else {
                    throw failure("Reconnect the VPN before changing routing for this profile.")
                }
                guard let session = manager.connection as? NETunnelProviderSession else {
                    throw failure("The VPN session is unavailable.")
                }
                let data = try JSONSerialization.data(withJSONObject: ["command": "set_bypass", "enabled": enabled])
                let reply = try await send(data, to: session)
                guard let result = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
                    throw failure("The VPN extension returned an invalid routing confirmation.")
                }
                guard result["ok"] as? Bool == true,
                      result["enabled"] as? Bool == enabled else {
                    throw failure(result["message"] as? String ?? "The VPN extension could not apply the routing change.")
                }
                confirmedConnected = true
            case .disconnected, .invalid:
                break // Save for the next connection.
            default:
                throw failure("Wait until the VPN finishes connecting or disconnecting.")
            }
        }
        BypassTunnelPreference.defaults.set(enabled, forKey: BypassTunnelPreference.key)
        BypassTunnelPreference.defaults.synchronize()
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        if #available(iOS 16.2, *), var snapshot = VBridgeLiveActivityStore.load() {
            snapshot.content.phase = confirmedConnected ? .connected : .disconnected
            snapshot.content.bypassEnabled = enabled
            snapshot.content.updatedAt = .now
            VBridgeLiveActivityStore.save(snapshot)
            for activity in Activity<VBridgeVPNLiveActivityAttributes>.activities {
                if confirmedConnected {
                    await activity.update(ActivityContent(state: snapshot.content, staleDate: Date().addingTimeInterval(120)))
                } else {
                    await activity.end(ActivityContent(state: snapshot.content, staleDate: nil), dismissalPolicy: .immediate)
                }
            }
        }
#endif
    }

    private final class Reply {
        var continuation: CheckedContinuation<Data, Error>?
        func finish(_ result: Result<Data, Error>) {
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    private static func send(_ data: Data, to session: NETunnelProviderSession) async throws -> Data {
        let reply = Reply()
        return try await withCheckedThrowingContinuation { continuation in
            reply.continuation = continuation
            let timeout = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled else { return }
                reply.finish(.failure(failure("The VPN extension did not respond. Check routing before retrying.")))
            }
            do {
                try session.sendProviderMessage(data) { response in
                    Task { @MainActor in
                        timeout.cancel()
                        if let response { reply.finish(.success(response)) }
                        else { reply.finish(.failure(failure("The VPN extension returned no routing confirmation."))) }
                    }
                }
            } catch {
                timeout.cancel()
                reply.finish(.failure(error))
            }
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "VBridge.BypassTunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
