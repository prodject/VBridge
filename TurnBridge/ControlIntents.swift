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
    static var description = IntentDescription("Opens VBridge and connects or disconnects the last used profile.")
    static var openAppWhenRun = true
    static var isDiscoverable = true

    @Parameter(title: "Connected")
    var value: Bool

    func perform() async throws -> some IntentResult {
        PendingShortcutActionStore.store(value ? .connect : .disconnect)
        return .result()
    }
}
