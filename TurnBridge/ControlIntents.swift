import AppIntents

@available(iOS 18.0, *)
struct ConnectVPNControlIntent: AppIntent {
    static var title: LocalizedStringResource = "Connect VBridge VPN"
    static var description = IntentDescription("Opens VBridge and connects the tunnel.")
    static var openAppWhenRun = true
    static var isDiscoverable = true

    func perform() async throws -> some IntentResult {
        PendingShortcutActionStore.store(.connect)
        return .result()
    }
}
