//
//  Created by nullcstring.
//

import SwiftUI
import NetworkExtension
#if !targetEnvironment(macCatalyst)
import AppIntents
#endif

@main
struct VBridge: App {
    @AppStorage("appTheme") private var appTheme = "system"
    private let tunnelBackend = TunnelBackendFactory.make()

    init() {
        SplitTunnelStorage.migrateLegacyStorageIfNeeded()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        SharedLogger.info("App launched: version=\(version), build=\(build)")
        UserNotificationDispatcher.shared.requestAuthorizationIfNeeded()
#if !targetEnvironment(macCatalyst)
        if #available(iOS 16.0, *) {
            VBridgeAppShortcuts.updateAppShortcutParameters()
        }
#endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView(app: self)
                .tint(Color(red: 0.59, green: 0.41, blue: 0.98))
                .preferredColorScheme(preferredColorScheme)
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch appTheme {
        case "light":
            return .light
        case "dark":
            return .dark
        default:
            return nil
        }
    }

    func turnOnTunnel(
        vkLink: String,
        peerAddr: String,
        listenAddr: String,
        nValue: Int,
        credsGroupSize: Int,
        wgQuickConfig: String,
        turnHost: String,
        turnPort: String,
        useUdp: Bool,
        transportMode: VPNTransportMode,
        wrapKeyHex: String,
        wdttPassword: String,
        wdttClientKey: String,
        wdttServerKey: String,
        wdttFingerprint: String,
        wdttClientIDMode: String,
        wdttUseVKCallsPreflight: Bool,
        wdttTunnelMTU: Int?,
        seededTURN: SeededTURNCredentials? = nil,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let configuration = TunnelStartConfiguration(
            vkLink: vkLink,
            peerAddr: peerAddr,
            listenAddr: listenAddr,
            nValue: nValue,
            credsGroupSize: credsGroupSize,
            wgQuickConfig: wgQuickConfig,
            turnHost: turnHost,
            turnPort: turnPort,
            useUdp: useUdp,
            transportMode: transportMode,
            wrapKeyHex: wrapKeyHex,
            wdttPassword: wdttPassword,
            wdttClientKey: wdttClientKey,
            wdttServerKey: wdttServerKey,
            wdttFingerprint: wdttFingerprint,
            wdttClientIDMode: wdttClientIDMode,
            wdttUseVKCallsPreflight: wdttUseVKCallsPreflight,
            wdttTunnelMTU: wdttTunnelMTU,
            seededTURN: seededTURN
        )
        tunnelBackend.start(configuration, completionHandler: completionHandler)
    }

    func turnOffTunnel() {
        tunnelBackend.stop()
    }
}
