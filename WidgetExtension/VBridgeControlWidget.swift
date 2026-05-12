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
            ) { isOn in
                Label(
                    isOn ? "Connected" : "Disconnected",
                    systemImage: isOn ? "lock.shield.fill" : "lock.shield"
                )
                .controlWidgetActionHint(isOn ? "Disconnect the last used profile" : "Connect the last used profile")
                .controlWidgetStatus(isOn ? "Connected" : "Disconnected")
            }
            .tint(.blue)
        }
        .displayName("VBridge")
        .description("Connect or disconnect the last used VPN profile from Control Center.")
    }
}
