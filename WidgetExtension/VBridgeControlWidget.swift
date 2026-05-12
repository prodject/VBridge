import AppIntents
import SwiftUI
import WidgetKit

@available(iOS 18.0, *)
struct VBridgeConnectControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.prodject.vbridge.control.connect") {
            ControlWidgetButton(action: ToggleVPNControlIntent()) {
                Label("VBridge", systemImage: "lock.shield")
                    .controlWidgetActionHint("Connect or disconnect VPN")
            }
        }
        .displayName("VBridge")
        .description("Connect or disconnect the VPN from Control Center.")
    }
}
