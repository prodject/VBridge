import Foundation
import NetworkExtension

struct TunnelStartConfiguration: Codable {
    var vkLink: String
    var peerAddr: String
    var listenAddr: String
    var nValue: Int
    var credsGroupSize: Int
    var wgQuickConfig: String
    var turnHost: String
    var turnPort: String
    var useUdp: Bool
    var transportMode: VPNTransportMode
    var wrapKeyHex: String
    var wdttPassword: String
    var wdttClientKey: String
    var wdttServerKey: String
    var seededTURN: SeededTURNCredentials?

    var normalizedWgQuickConfig: String {
        Self.normalizedWgQuickConfig(wgQuickConfig, listenAddr: listenAddr)
    }

    var providerConfiguration: [String: Any] {
        var configuration: [String: Any] = [
            "wgQuickConfig": normalizedWgQuickConfig,
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
            configuration["seededTURN"] = seededTURN.providerConfiguration
        }

        return configuration
    }

    private static func normalizedWgQuickConfig(_ wgQuickConfig: String, listenAddr: String) -> String {
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
}

protocol TunnelBackend {
    func start(_ configuration: TunnelStartConfiguration, completionHandler: @escaping (Bool) -> Void)
    func stop()
}

enum TunnelBackendFactory {
    static func make() -> TunnelBackend {
#if targetEnvironment(macCatalyst)
        return MacPrivilegedHelperTunnelBackend()
#else
        return NetworkExtensionTunnelBackend()
#endif
    }
}

final class NetworkExtensionTunnelBackend: TunnelBackend {
    func start(_ configuration: TunnelStartConfiguration, completionHandler: @escaping (Bool) -> Void) {
        SharedLogger.info("Connecting... mode=\(configuration.transportMode.rawValue), peer=\(configuration.peerAddr), listen=\(configuration.listenAddr), n=\(configuration.nValue)")
        if configuration.transportMode == .wdtt {
            SharedLogger.info("WDTT start config: vkLinkLen=\(configuration.vkLink.count), passwordSet=\(!configuration.wdttPassword.isEmpty), primaryHashLen=\(configuration.wdttClientKey.count), extraHashesLen=\(configuration.wdttServerKey.count)")
        }

        let currentAppBundleId = Bundle.main.bundleIdentifier ?? "com.prodject.vbridge"
        let providerBundleIdentifier = Self.packetTunnelProviderBundleIdentifier(appBundleIdentifier: currentAppBundleId)
        SharedLogger.debug("Packet tunnel provider id: app=\(currentAppBundleId), provider=\(providerBundleIdentifier)")

        NETunnelProviderManager.loadAllFromPreferences { tunnelManagersInSettings, error in
            if let error {
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
            protocolConfiguration.serverAddress = configuration.peerAddr.components(separatedBy: ":").first ?? configuration.peerAddr
            protocolConfiguration.providerConfiguration = configuration.providerConfiguration

            let defaults = UserDefaults.standard
            let excludeAPNs = defaults.object(forKey: "excludeAPNs") as? Bool ?? false
            let excludeCellular = defaults.object(forKey: "excludeCellularServices") as? Bool ?? false
            let excludeLAN = defaults.object(forKey: "excludeLocalNetworks") as? Bool ?? true

            protocolConfiguration.includeAllNetworks = false
            protocolConfiguration.excludeAPNs = excludeAPNs
            protocolConfiguration.excludeCellularServices = excludeCellular
            protocolConfiguration.excludeLocalNetworks = excludeLAN

            let manualCaptcha = UserDefaults.standard.bool(forKey: "manualCaptcha")
            SharedLogger.debug("Routing: LAN=\(excludeLAN), APNs=\(excludeAPNs), Cellular=\(excludeCellular), ManualCaptcha=\(manualCaptcha)")
            let configuredProviderBundleID = protocolConfiguration.providerBundleIdentifier ?? "nil"
            NSLog("ProviderBundleID configured = \(configuredProviderBundleID)")
            SharedLogger.info("ProviderBundleID configured = \(configuredProviderBundleID)")

            if let seededTURN = configuration.seededTURN {
                SharedLogger.info("Using seeded TURN credentials: addr=\(seededTURN.address)")
            }

            tunnelManager.protocolConfiguration = protocolConfiguration
            tunnelManager.localizedDescription = "VBridge"
            tunnelManager.isEnabled = true
            tunnelManager.saveToPreferences { error in
                if let error {
                    NSLog("Error (saveToPreferences): \(error)")
                    SharedLogger.error("Failed to save tunnel preferences: \(error.localizedDescription)")
                    completionHandler(false)
                    return
                }

                tunnelManager.loadFromPreferences { error in
                    if let error {
                        NSLog("Error (loadFromPreferences): \(error)")
                        SharedLogger.error("Failed to reload tunnel preferences: \(error.localizedDescription)")
                        completionHandler(false)
                        return
                    }

                    if let proto = tunnelManager.protocolConfiguration as? NETunnelProviderProtocol {
                        let loadedProviderBundleID = proto.providerBundleIdentifier ?? "nil"
                        NSLog("ProviderBundleID loaded = \(loadedProviderBundleID)")
                        SharedLogger.info("ProviderBundleID loaded = \(loadedProviderBundleID)")
                    } else {
                        NSLog("ProviderBundleID loaded = nil protocol")
                        SharedLogger.warning("ProviderBundleID loaded = nil protocol")
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

    func stop() {
        SharedLogger.info("Disconnecting...")
        NETunnelProviderManager.loadAllFromPreferences { tunnelManagersInSettings, error in
            if let error {
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
            schedulePostStartDiagnosticIfNeeded(
                session: session,
                providerBundleIdentifier: providerBundleIdentifier,
                recoveryAttempted: recoveryAttempted
            )
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

    private func schedulePostStartDiagnosticIfNeeded(
        session: NETunnelProviderSession,
        providerBundleIdentifier: String?,
        recoveryAttempted: Bool
    ) {
#if os(macOS) || targetEnvironment(macCatalyst)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            guard session.status == .disconnected || session.status == .invalid else { return }
            let providerID = providerBundleIdentifier ?? "unknown"
            SharedLogger.error(
                "macOS tunnel provider did not launch after startTunnel; status=\(session.status.rawValue), provider=\(providerID), recoveryAttempted=\(recoveryAttempted). If there are no TUNNEL logs after this point, macOS rejected the Network Extension before PacketTunnelProvider.startTunnel. A DMG signed ad-hoc can build and save VPN preferences, but running packet-tunnel providers on macOS usually requires a Developer ID/provisioned signature with the Network Extension entitlement."
            )
        }
#endif
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
}

final class MacPrivilegedHelperTunnelBackend: TunnelBackend {
    private let helperURL = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/com.prodject.vbridge.helper")

    func start(_ configuration: TunnelStartConfiguration, completionHandler: @escaping (Bool) -> Void) {
#if targetEnvironment(macCatalyst)
        SharedLogger.info("Connecting... mode=\(configuration.transportMode.rawValue), peer=\(configuration.peerAddr), listen=\(configuration.listenAddr), n=\(configuration.nValue)")
        if configuration.transportMode == .wdtt {
            SharedLogger.info("WDTT start config: vkLinkLen=\(configuration.vkLink.count), passwordSet=\(!configuration.wdttPassword.isEmpty), primaryHashLen=\(configuration.wdttClientKey.count), extraHashesLen=\(configuration.wdttServerKey.count)")
        }

        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            SharedLogger.error("macOS privileged helper is not installed at \(helperURL.path). The shared macOS backend layer is active, but a root helper/CLI is required to create utun routes and DNS without NetworkExtension.")
            completionHandler(false)
            return
        }

        do {
            let configURL = try writeConfiguration(configuration)
            try runHelper(arguments: ["start", "--config", configURL.path])
            SharedLogger.info("macOS privileged helper start requested")
            completionHandler(true)
        } catch {
            SharedLogger.error("macOS privileged helper start failed: \(error.localizedDescription)")
            completionHandler(false)
        }
#else
        completionHandler(false)
#endif
    }

    func stop() {
#if targetEnvironment(macCatalyst)
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            SharedLogger.warning("macOS privileged helper is not installed, nothing to stop")
            return
        }

        do {
            try runHelper(arguments: ["stop"])
            SharedLogger.info("macOS privileged helper stop requested")
        } catch {
            SharedLogger.error("macOS privileged helper stop failed: \(error.localizedDescription)")
        }
#endif
    }

#if targetEnvironment(macCatalyst)
    private func writeConfiguration(_ configuration: TunnelStartConfiguration) throws -> URL {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("VBridge", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("VBridge", isDirectory: true)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("helper-start.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: configURL, options: [.atomic])
        return configURL
    }

    private func runHelper(arguments: [String]) throws {
        let process = Process()
        process.executableURL = helperURL
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "VBridge.MacPrivilegedHelper",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message?.isEmpty == false ? message! : "helper exited with status \(process.terminationStatus)"]
            )
        }
    }
#endif
}
