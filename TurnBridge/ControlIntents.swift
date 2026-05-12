import AppIntents

@available(iOS 18.0, *)
struct ToggleVPNControlIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle VBridge VPN"
    static var description = IntentDescription("Opens VBridge and toggles the tunnel.")
    static var openAppWhenRun = true
    static var isDiscoverable = true

    func perform() async throws -> some IntentResult {
        PendingShortcutActionStore.store(.toggle)
        return .result()
    }
}
