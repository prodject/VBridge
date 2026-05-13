//
//  Created by nullcstring.
//

import SwiftUI
import NetworkExtension
import AppIntents

@main
struct VBridge: App {
    @AppStorage("appTheme") private var appTheme = "system"

    init() {
        UserNotificationDispatcher.shared.requestAuthorizationIfNeeded()
        if #available(iOS 16.0, *) {
            VBridgeAppShortcuts.updateAppShortcutParameters()
        }
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

    private func normalizedWgQuickConfig(_ wgQuickConfig: String, listenAddr: String) -> String {
        var inPeerSection = false
        var rewrittenLines: [String] = []
        rewrittenLines.reserveCapacity(wgQuickConfig.count / 16)

        for line in wgQuickConfig.components(separatedBy: .newlines) {
            let lineWithoutHashComment: String
            if let commentRange = line.range(of: "#") {
                lineWithoutHashComment = String(line[..<commentRange.lowerBound])
            } else {
                lineWithoutHashComment = line
            }

            let trimmedLine = lineWithoutHashComment.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercasedLine = trimmedLine.lowercased()

            if lowercasedLine == "[peer]" {
                inPeerSection = true
                rewrittenLines.append(line)
                continue
            }

            if lowercasedLine == "[interface]" {
                inPeerSection = false
                rewrittenLines.append(line)
                continue
            }

            if inPeerSection, let equalsIndex = trimmedLine.firstIndex(of: "=") {
                let key = trimmedLine[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if key == "endpoint" {
                    rewrittenLines.append("Endpoint = \(listenAddr)")
                    continue
                }
            }

            rewrittenLines.append(line)
        }

        return rewrittenLines.joined(separator: "\n")
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
        completionHandler: @escaping (Bool) -> Void
    ) {
        SharedLogger.info("Connecting... peer=\(peerAddr), listen=\(listenAddr), n=\(nValue)")
        let normalizedConfig = normalizedWgQuickConfig(wgQuickConfig, listenAddr: listenAddr)

        NETunnelProviderManager.loadAllFromPreferences { tunnelManagersInSettings, error in
            if let error = error {
                NSLog("Error (loadAllFromPreferences): \(error)")
                SharedLogger.error("Failed to load tunnel preferences: \(error.localizedDescription)")
                completionHandler(false)
                return
            }

            let preExistingTunnelManager = tunnelManagersInSettings?.first
            let tunnelManager = preExistingTunnelManager ?? NETunnelProviderManager()
            SharedLogger.debug("Using \(preExistingTunnelManager != nil ? "existing" : "new") tunnel manager")

            let protocolConfiguration = NETunnelProviderProtocol()
            let currentAppBundleId = Bundle.main.bundleIdentifier ?? "com.prodject.vbridge"
            protocolConfiguration.providerBundleIdentifier = "\(currentAppBundleId).network-extension"
            let cleanIP = peerAddr.components(separatedBy: ":").first ?? peerAddr
            protocolConfiguration.serverAddress = cleanIP

            protocolConfiguration.providerConfiguration = [
                "wgQuickConfig": normalizedConfig,
                "vkLink": vkLink,
                "peerAddr": peerAddr,
                "listenAddr": listenAddr,
                "nValue": nValue,
                "credsGroupSize": max(credsGroupSize, 1),
                "manualCaptcha": UserDefaults.standard.bool(forKey: "manualCaptcha"),
                "turnHost": turnHost,
                "turnPort": turnPort,
                "useUdp": useUdp
            ]

            let defaults = UserDefaults.standard
            let excludeAPNs = defaults.object(forKey: "excludeAPNs") as? Bool ?? false
            let excludeCellular = defaults.object(forKey: "excludeCellularServices") as? Bool ?? false
            let excludeLAN = defaults.object(forKey: "excludeLocalNetworks") as? Bool ?? true

            // Keep Internet available while manual captcha is being solved.
            // With includeAllNetworks=true iOS can route browser traffic into a
            // not-yet-ready tunnel during Connecting, causing blank captcha pages.
            protocolConfiguration.includeAllNetworks = false
            protocolConfiguration.excludeAPNs = excludeAPNs
            protocolConfiguration.excludeCellularServices = excludeCellular
            protocolConfiguration.excludeLocalNetworks = excludeLAN

            let manualCaptcha = UserDefaults.standard.bool(forKey: "manualCaptcha")
            SharedLogger.debug("Routing: LAN=\(excludeLAN), APNs=\(excludeAPNs), Cellular=\(excludeCellular), ManualCaptcha=\(manualCaptcha)")

            tunnelManager.protocolConfiguration = protocolConfiguration
            tunnelManager.isEnabled = true
            tunnelManager.saveToPreferences { error in
                if let error = error {
                    NSLog("Error (saveToPreferences): \(error)")
                    SharedLogger.error("Failed to save tunnel preferences: \(error.localizedDescription)")
                    completionHandler(false)
                    return
                }
                tunnelManager.loadFromPreferences { error in
                    if let error = error {
                        NSLog("Error (loadFromPreferences): \(error)")
                        SharedLogger.error("Failed to reload tunnel preferences: \(error.localizedDescription)")
                        completionHandler(false)
                        return
                    }

                    guard let session = tunnelManager.connection as? NETunnelProviderSession else {
                        SharedLogger.error("tunnelManager.connection is not NETunnelProviderSession")
                        completionHandler(false)
                        return
                    }
                    do {
                        SharedLogger.info("Starting tunnel session...")
                        try session.startTunnel()
                        completionHandler(true)
                    } catch {
                        NSLog("Error (startTunnel): \(error)")
                        SharedLogger.error("Failed to start tunnel: \(error.localizedDescription)")
                        completionHandler(false)
                    }
                }
            }
        }
    }

    func turnOffTunnel() {
        SharedLogger.info("Disconnecting...")
        NETunnelProviderManager.loadAllFromPreferences { tunnelManagersInSettings, error in
            if let error = error {
                NSLog("Error (loadAllFromPreferences): \(error)")
                SharedLogger.error("Failed to load tunnel preferences: \(error.localizedDescription)")
                return
            }
            if let tunnelManager = tunnelManagersInSettings?.first {
                guard let session = tunnelManager.connection as? NETunnelProviderSession else {
                    SharedLogger.error("tunnelManager.connection is not NETunnelProviderSession")
                    return
                }
                switch session.status {
                case .connected, .connecting, .reasserting:
                    SharedLogger.info("Stopping tunnel session...")
                    session.stopTunnel()
                default:
                    SharedLogger.warning("Tunnel not in active state, nothing to stop")
                }
            } else {
                SharedLogger.warning("No tunnel manager found")
            }
        }
    }
}
