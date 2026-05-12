import AppIntents
import SwiftUI
import WidgetKit

private enum WidgetControlActionStore {
    static let suiteName = "group.com.prodject.vbridge"
    static let key = "pending.shortcut.action"

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    static func storeToggleAction() {
        defaults?.set("toggle", forKey: key)
        defaults?.synchronize()
    }
}

@available(iOS 18.0, *)
private struct WidgetToggleVPNControlIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle VBridge VPN"
    static var description = IntentDescription("Opens VBridge and toggles the tunnel.")
    static var openAppWhenRun = true
    static var isDiscoverable = true

    func perform() async throws -> some IntentResult {
        WidgetControlActionStore.storeToggleAction()
        return .result()
    }
}

@available(iOS 18.0, *)
struct VBridgeConnectControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.prodject.vbridge.control.connect") {
            ControlWidgetButton(action: WidgetToggleVPNControlIntent()) {
                Label("VBridge", systemImage: "lock.shield")
                    .controlWidgetActionHint("Connect or disconnect VPN")
            }
        }
        .displayName("VBridge")
        .description("Connect or disconnect the VPN from Control Center.")
    }
}
