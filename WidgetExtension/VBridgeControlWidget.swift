import AppIntents
import SwiftUI
import WidgetKit

private enum WidgetControlActionStore {
    static let suiteName = "group.com.prodject.vbridge"
    static let key = "pending.shortcut.action"

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    static func storeConnectAction() {
        defaults?.set("connect", forKey: key)
    }
}

@available(iOS 18.0, *)
struct ConnectVPNControlIntent: AppIntent {
    static var title: LocalizedStringResource = "Connect VBridge VPN"
    static var description = IntentDescription("Opens VBridge and connects the tunnel.")
    static var openAppWhenRun = true
    static var isDiscoverable = true

    func perform() async throws -> some IntentResult {
        WidgetControlActionStore.storeConnectAction()
        return .result()
    }
}

@available(iOS 18.0, *)
struct VBridgeConnectControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.prodject.vbridge.control.connect") {
            ControlWidgetButton(action: ConnectVPNControlIntent()) {
                Label {
                    Text("VPN")
                } icon: {
                    Image(systemName: "wave.3.right.circle")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.gray.opacity(0.82))
                }
                .controlWidgetActionHint("Connect VPN")
            }
        }
        .displayName("VBridge Connect")
        .description("Connect the VPN from Control Center.")
    }
}
