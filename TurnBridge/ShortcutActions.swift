#if !targetEnvironment(macCatalyst)
import AppIntents

@available(iOS 16.0, *)
struct ToggleVPNIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle VBridge VPN"
    static var description = IntentDescription("Opens VBridge and toggles the tunnel.")
    static var openAppWhenRun = true
    static var isDiscoverable = true

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
    static var isDiscoverable = true

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
    static var isDiscoverable = true

    func perform() async throws -> some IntentResult {
        PendingShortcutActionStore.store(.disconnect)
        return .result()
    }
}

@available(iOS 16.0, *)
struct VBridgeAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleVPNIntent(),
            phrases: [
                "Toggle VPN in \(.applicationName)",
                "Switch VPN in \(.applicationName)"
            ],
            shortTitle: "Toggle VPN",
            systemImageName: "arrow.2.circlepath"
        )
        AppShortcut(
            intent: ConnectVPNIntent(),
            phrases: [
                "Connect VPN in \(.applicationName)",
                "Start VPN in \(.applicationName)"
            ],
            shortTitle: "Connect VPN",
            systemImageName: "lock.shield"
        )
        AppShortcut(
            intent: DisconnectVPNIntent(),
            phrases: [
                "Disconnect VPN in \(.applicationName)",
                "Stop VPN in \(.applicationName)"
            ],
            shortTitle: "Disconnect VPN",
            systemImageName: "lock.open"
        )
    }
}
#endif
