import AppIntents
import SwiftUI
import WidgetKit

@available(iOS 18.0, *)
struct VBridgeConnectControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: VBridgeControlKind.connect,
            provider: VBridgeControlValueProvider()
        ) { isConnected in
            ControlWidgetToggle(
                "VBridge",
                isOn: isConnected,
                action: ToggleVPNControlIntent()
            ) {
                Image(systemName: isConnected ? "wave.3.right.circle.fill" : "wave.3.right.circle")
                    .controlWidgetActionHint(isConnected ? "Disconnect the last used profile" : "Connect the last used profile")
                    .controlWidgetStatus(isConnected ? "Connected" : "Disconnected")
            }
            .tint(.blue)
        }
        .displayName("VBridge")
        .description("Connect or disconnect the last used VPN profile from Control Center.")
    }
}
