import AppIntents
import Foundation

enum PendingShortcutAction: String {
    case toggle
    case connect
    case disconnect
}

enum PendingShortcutActionStore {
    private static let suiteName = "group.com.prodject.vbridge"
    private static let key = "pending.shortcut.action"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    static func store(_ action: PendingShortcutAction) {
        defaults?.set(action.rawValue, forKey: key)
    }

    static func consume() -> PendingShortcutAction? {
        guard let defaults else { return nil }
        defer { defaults.removeObject(forKey: key) }
        guard let rawValue = defaults.string(forKey: key) else { return nil }
        return PendingShortcutAction(rawValue: rawValue)
    }
}

@available(iOS 16.0, *)
struct ToggleVPNIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle VBridge VPN"
    static var description = IntentDescription("Opens VBridge and toggles the tunnel.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        PendingShortcutActionStore.store(.toggle)
        return .result()
    }
}

@available(iOS 16.0, *)
struct ConnectVPNIntent: AppIntent {
    static var title: LocalizedStringResource = "Connect VBridge VPN"
    static var description = IntentDescription("Opens VBridge and connects the tunnel.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        PendingShortcutActionStore.store(.connect)
        return .result()
    }
}

@available(iOS 16.0, *)
struct DisconnectVPNIntent: AppIntent {
    static var title: LocalizedStringResource = "Disconnect VBridge VPN"
    static var description = IntentDescription("Opens VBridge and disconnects the tunnel.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        PendingShortcutActionStore.store(.disconnect)
        return .result()
    }
}

@available(iOS 16.0, *)
struct VBridgeAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        [
            AppShortcut(
                intent: ToggleVPNIntent(),
                phrases: [
                    "Toggle VPN in \(.applicationName)",
                    "Switch VPN in \(.applicationName)"
                ],
                shortTitle: "Toggle VPN",
                systemImageName: "arrow.2.circlepath"
            ),
            AppShortcut(
                intent: ConnectVPNIntent(),
                phrases: [
                    "Connect VPN in \(.applicationName)",
                    "Start VPN in \(.applicationName)"
                ],
                shortTitle: "Connect VPN",
                systemImageName: "lock.shield"
            ),
            AppShortcut(
                intent: DisconnectVPNIntent(),
                phrases: [
                    "Disconnect VPN in \(.applicationName)",
                    "Stop VPN in \(.applicationName)"
                ],
                shortTitle: "Disconnect VPN",
                systemImageName: "lock.open"
            )
        ]
    }
}
