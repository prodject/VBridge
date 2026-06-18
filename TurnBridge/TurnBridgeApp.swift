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
        transportMode: VPNTransportMode,
        wrapKeyHex: String,
        wdttPassword: String,
        wdttClientKey: String,
        wdttServerKey: String,
        seededTURN: SeededTURNCredentials? = nil,
        completionHandler: @escaping (Bool) -> Void
    ) {
        SharedLogger.info("Connecting... mode=\(transportMode.rawValue), peer=\(peerAddr), listen=\(listenAddr), n=\(nValue)")
        if transportMode == .wdtt {
            SharedLogger.info("WDTT start config: vkLinkLen=\(vkLink.count), passwordSet=\(!wdttPassword.isEmpty), primaryHashLen=\(wdttClientKey.count), extraHashesLen=\(wdttServerKey.count)")
        }
        let normalizedConfig = normalizedWgQuickConfig(wgQuickConfig, listenAddr: listenAddr)
        let currentAppBundleId = Bundle.main.bundleIdentifier ?? "com.prodject.vbridge"
        let providerBundleIdentifier = Self.packetTunnelProviderBundleIdentifier(appBundleIdentifier: currentAppBundleId)
        SharedLogger.debug("Packet tunnel provider id: app=\(currentAppBundleId), provider=\(providerBundleIdentifier)")

        NETunnelProviderManager.loadAllFromPreferences { tunnelManagersInSettings, error in
            if let error = error {
                NSLog("Error (loadAllFromPreferences): \(error)")
                SharedLogger.error("Failed to load tunnel preferences: \(error.localizedDescription)")
                completionHandler(false)
                return
            }

            let preExistingTunnelManager = tunnelManagersInSettings?.first {
                guard let protocolConfiguration = $0.protocolConfiguration as? NETunnelProviderProtocol else {
                    return false
                }
                return protocolConfiguration.providerBundleIdentifier == providerBundleIdentifier
            } ?? tunnelManagersInSettings?.first
            let tunnelManager = preExistingTunnelManager ?? NETunnelProviderManager()
            SharedLogger.debug("Using \(preExistingTunnelManager != nil ? "existing" : "new") tunnel manager")

            let protocolConfiguration = NETunnelProviderProtocol()
            protocolConfiguration.providerBundleIdentifier = providerBundleIdentifier
            let cleanIP = peerAddr.components(separatedBy: ":").first ?? peerAddr
            protocolConfiguration.serverAddress = cleanIP

            var providerConfiguration: [String: Any] = [
                "wgQuickConfig": normalizedConfig,
                "vkLink": vkLink,
                "peerAddr": peerAddr,
                "listenAddr": listenAddr,
                "nValue": nValue,
                "credsGroupSize": max(credsGroupSize, 1),
                "manualCaptcha": UserDefaults.standard.bool(forKey: "manualCaptcha"),
                "turnHost": turnHost,
                "turnPort": turnPort,
                "useUdp": useUdp,
                "transportMode": transportMode.rawValue,
                "wrapKeyHex": wrapKeyHex,
                "wdttPassword": wdttPassword,
                "wdttClientKey": wdttClientKey,
                "wdttServerKey": wdttServerKey
            ]
            if let seededTURN {
                providerConfiguration["seededTURN"] = seededTURN.providerConfiguration
                SharedLogger.info("Using seeded TURN credentials: addr=\(seededTURN.address)")
            }
            protocolConfiguration.providerConfiguration = providerConfiguration

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
            tunnelManager.localizedDescription = "VBridge"
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
                    self.startTunnelSessionAfterPolicySettle(
                        session,
                        retriesRemaining: 5,
                        recoveryConfiguration: protocolConfiguration,
                        providerBundleIdentifier: providerBundleIdentifier,
                        completionHandler: completionHandler
                    )
                }
            }
        }
    }

    private static func packetTunnelProviderBundleIdentifier(appBundleIdentifier: String) -> String {
        if let plugInsURL = Bundle.main.builtInPlugInsURL {
            for appexName in ["PacketTunnel.appex", "network-extension.appex"] {
                let appexURL = plugInsURL.appendingPathComponent(appexName)
                if let appexBundle = Bundle(url: appexURL),
                   let bundleIdentifier = appexBundle.bundleIdentifier,
                   !bundleIdentifier.isEmpty {
                    return bundleIdentifier
                }
            }
        }

        return "\(appBundleIdentifier).tunnel"
    }

    private func startTunnelSessionAfterPolicySettle(
        _ session: NETunnelProviderSession,
        retriesRemaining: Int,
        recoveryConfiguration: NETunnelProviderProtocol? = nil,
        providerBundleIdentifier: String? = nil,
        recoveryAttempted: Bool = false,
        completionHandler: @escaping (Bool) -> Void
    ) {
        SharedLogger.debug("Waiting 700ms for VPN policy settle before startTunnel")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            self.startTunnelSession(
                session,
                retriesRemaining: retriesRemaining,
                recoveryConfiguration: recoveryConfiguration,
                providerBundleIdentifier: providerBundleIdentifier,
                recoveryAttempted: recoveryAttempted,
                completionHandler: completionHandler
            )
        }
    }

    private func startTunnelSession(
        _ session: NETunnelProviderSession,
        retriesRemaining: Int,
        recoveryConfiguration: NETunnelProviderProtocol? = nil,
        providerBundleIdentifier: String? = nil,
        recoveryAttempted: Bool = false,
        completionHandler: @escaping (Bool) -> Void
    ) {
        if session.status == .disconnecting, retriesRemaining > 0 {
            SharedLogger.warning("Tunnel session still disconnecting; retrying start in 1s (remaining=\(retriesRemaining))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.startTunnelSession(
                    session,
                    retriesRemaining: retriesRemaining - 1,
                    recoveryConfiguration: recoveryConfiguration,
                    providerBundleIdentifier: providerBundleIdentifier,
                    recoveryAttempted: recoveryAttempted,
                    completionHandler: completionHandler
                )
            }
            return
        }

        do {
            SharedLogger.info("Starting tunnel session... status=\(session.status.rawValue)")
            try session.startTunnel()
            scheduleStartRecoveryIfNeeded(
                session: session,
                recoveryConfiguration: recoveryConfiguration,
                providerBundleIdentifier: providerBundleIdentifier,
                recoveryAttempted: recoveryAttempted
            )
            completionHandler(true)
        } catch {
            NSLog("Error (startTunnel): \(error)")
            SharedLogger.error("Failed to start tunnel: \(error.localizedDescription)")
            completionHandler(false)
        }
    }

    private func scheduleStartRecoveryIfNeeded(
        session: NETunnelProviderSession,
        recoveryConfiguration: NETunnelProviderProtocol?,
        providerBundleIdentifier: String?,
        recoveryAttempted: Bool
    ) {
        guard !recoveryAttempted,
              let recoveryConfiguration,
              let providerBundleIdentifier else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            guard session.status == .disconnected else { return }
            SharedLogger.warning("Tunnel returned to disconnected after start; recreating VPN manager once")
            self.recreateAndStartTunnel(
                protocolConfiguration: recoveryConfiguration,
                providerBundleIdentifier: providerBundleIdentifier
            )
        }
    }

    private func recreateAndStartTunnel(
        protocolConfiguration: NETunnelProviderProtocol,
        providerBundleIdentifier: String
    ) {
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let error {
                SharedLogger.error("Failed to load tunnel managers for recovery: \(error.localizedDescription)")
                return
            }

            let matchingManagers = (managers ?? []).filter { manager in
                guard let protocolConfiguration = manager.protocolConfiguration as? NETunnelProviderProtocol else {
                    return false
                }
                return protocolConfiguration.providerBundleIdentifier == providerBundleIdentifier
            }

            self.removeManagers(matchingManagers) {
                let manager = NETunnelProviderManager()
                manager.protocolConfiguration = protocolConfiguration
                manager.localizedDescription = "VBridge"
                manager.isEnabled = true
                manager.saveToPreferences { error in
                    if let error {
                        SharedLogger.error("Failed to save recreated tunnel manager: \(error.localizedDescription)")
                        return
                    }
                    manager.loadFromPreferences { error in
                        if let error {
                            SharedLogger.error("Failed to reload recreated tunnel manager: \(error.localizedDescription)")
                            return
                        }
                        guard let session = manager.connection as? NETunnelProviderSession else {
                            SharedLogger.error("recreated tunnelManager.connection is not NETunnelProviderSession")
                            return
                        }
                        self.startTunnelSessionAfterPolicySettle(
                            session,
                            retriesRemaining: 0,
                            recoveryAttempted: true
                        ) { started in
                            SharedLogger.info("Recreated tunnel manager start \(started ? "requested" : "failed")")
                        }
                    }
                }
            }
        }
    }

    private func removeManagers(_ managers: [NETunnelProviderManager], completion: @escaping () -> Void) {
        guard let manager = managers.first else {
            completion()
            return
        }

        manager.removeFromPreferences { error in
            if let error {
                SharedLogger.warning("Failed to remove stale tunnel manager: \(error.localizedDescription)")
            }
            self.removeManagers(Array(managers.dropFirst()), completion: completion)
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
