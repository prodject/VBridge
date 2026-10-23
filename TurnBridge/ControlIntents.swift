#if !targetEnvironment(macCatalyst)
import Foundation
import AppIntents
import WidgetKit

@available(iOS 18.0, *)
enum VBridgeControlKind {
    static let connect = "com.prodject.vbridge.control.connect"
}

@available(iOS 18.0, *)
struct VBridgeControlValueProvider: ControlValueProvider {
    var previewValue: Bool {
        false
    }

    func currentValue() async throws -> Bool {
        guard let snapshot = VBridgeLiveActivityStore.load() else {
            return false
        }

        switch snapshot.content.phase {
        case .connected, .connecting, .disconnecting:
            return true
        case .disconnected, .unknown:
            return false
        }
    }
}

@available(iOS 18.0, *)
struct ToggleVPNControlIntent: SetValueIntent {
    static var title: LocalizedStringResource = "VBridge VPN"
    static var description = IntentDescription("Opens VBridge and connects or disconnects the last used profile when shared app-extension storage is available.")
    static var openAppWhenRun = true
    static var isDiscoverable = true

    @Parameter(title: "Connected")
    var value: Bool

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            PendingShortcutActionStore.store(value ? .connect : .disconnect)
        }
        return .result()
    }
}
// Shared with the widget; only the app installs the VPN control handler.
@available(iOS 17.0, *)
enum VBridgeLiveActivityAction {
    case setBypass(Bool)
    case disconnect
}

@available(iOS 17.0, *)
@MainActor
final class VBridgeLiveActivityActionRouter {
    static let shared = VBridgeLiveActivityActionRouter()
    var handler: ((VBridgeLiveActivityAction) async throws -> Void)?

    func perform(_ action: VBridgeLiveActivityAction) async throws {
        guard let handler else {
            throw NSError(domain: "VBridge.LiveActivity", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "VPN controls are unavailable. Open VBridge and retry."])
        }
        try await handler(action)
    }
}

@available(iOS 17.0, *)
struct SetBypassTunnelIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Bypass VPN Tunnel"
    static var isDiscoverable = false
    static var openAppWhenRun = false

    @Parameter(title: "Bypass VPN Tunnel") var enabled: Bool
    init() {}
    init(enabled: Bool) { self.enabled = enabled }

    func perform() async throws -> some IntentResult {
        try await VBridgeLiveActivityActionRouter.shared.perform(.setBypass(enabled))
        return .result()
    }
}

@available(iOS 17.0, *)
struct DisconnectVBridgeLiveActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Disconnect VBridge VPN"
    static var isDiscoverable = false
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult {
        try await VBridgeLiveActivityActionRouter.shared.perform(.disconnect)
        return .result()
    }
}
#endif
