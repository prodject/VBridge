import Foundation
import NetworkExtension
import Combine

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
    var wdttFingerprint: String
    var wdttClientIDMode: String
    var wdttUseVKCallsPreflight: Bool
    var wdttTunnelMTU: Int?
    var seededTURN: SeededTURNCredentials?

    var normalizedWgQuickConfig: String {
        Self.normalizedWgQuickConfig(wgQuickConfig, listenAddr: listenAddr)
    }

    var providerConfiguration: [String: Any] {
        let splitTunnel = SplitTunnelStorage.load()
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
            "wdttServerKey": wdttServerKey,
            "wdttFingerprint": wdttFingerprint,
            "wdttClientIDMode": wdttClientIDMode,
            "wdttUseVKCallsPreflight": wdttUseVKCallsPreflight,
            // PacketTunnel cannot read the app's Application Support directory,
            // and sideloaded builds often have no App Group entitlement. Pass the
            // current snapshot through NetworkExtension preferences so both signed
            // and sideloaded installations apply the same routing policy.
            "splitTunnelEnabled": splitTunnel.enabled,
            "splitTunnelMode": splitTunnel.mode.rawValue,
            "splitTunnelRuleCount": splitTunnel.rules.count
        ]

        if let rulesData = splitTunnel.rules.joined(separator: "\n").data(using: .utf8),
           let compressedRules = try? (rulesData as NSData).compressed(using: .lzfse) {
            configuration["splitTunnelRulesLZFSE"] = compressedRules
        }

        if let seededTURN {
            configuration["seededTURN"] = seededTURN.providerConfiguration
        }

        if let wdttTunnelMTU, wdttTunnelMTU > 0 {
            configuration["wdttTunnelMTU"] = wdttTunnelMTU
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

final class VBridgeTunnelManagerStore: ObservableObject {
    static let shared = VBridgeTunnelManagerStore()

    @Published private(set) var status: NEVPNStatus = .disconnected
    private(set) var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    private init() {}

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    static var providerBundleIdentifier: String {
        let appBundleIdentifier = Bundle.main.bundleIdentifier ?? "com.prodject.vbridge"
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

    static func matchingManagers(in managers: [NETunnelProviderManager]) -> [NETunnelProviderManager] {
        let expectedProvider = providerBundleIdentifier
        return managers.filter { manager in
            guard let configuration = manager.protocolConfiguration as? NETunnelProviderProtocol else {
                return false
            }
            return configuration.providerBundleIdentifier == expectedProvider
        }
    }

    static func preferredManager(in managers: [NETunnelProviderManager]) -> NETunnelProviderManager? {
        let matching = matchingManagers(in: managers)
        return matching.first {
            switch $0.connection.status {
            case .connected, .connecting, .reasserting, .disconnecting:
                return true
            default:
                return false
            }
        } ?? matching.first
    }

    func load(completion: @escaping (NETunnelProviderManager?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            DispatchQueue.main.async {
                if let error {
                    SharedLogger.error("Failed to load tunnel preferences: \(error.localizedDescription)")
                    completion(nil)
                    return
                }
                let matching = Self.matchingManagers(in: managers ?? [])
                if matching.count > 1 {
                    SharedLogger.warning("Found \(matching.count) VBridge VPN managers; using one preferred session")
                }
                let selected = Self.preferredManager(in: matching)
                if let selected {
                    self.adopt(selected)
                }
                completion(selected)
            }
        }
    }

    func adopt(_ manager: NETunnelProviderManager) {
        if self.manager === manager { return }
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
        self.manager = manager
        status = manager.connection.status
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: manager.connection,
            queue: .main
        ) { [weak self, weak manager] _ in
            guard let self, let manager, self.manager === manager else { return }
            self.status = manager.connection.status
        }
    }

    func clear(_ manager: NETunnelProviderManager? = nil) {
        if let manager, self.manager !== manager { return }
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
        statusObserver = nil
        self.manager = nil
        status = .disconnected
    }
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
    private let managerStore = VBridgeTunnelManagerStore.shared
    private var startupRecoveryWorkItem: DispatchWorkItem?

    func start(_ configuration: TunnelStartConfiguration, completionHandler: @escaping (Bool) -> Void) {
        startupRecoveryWorkItem?.cancel()
        startupRecoveryWorkItem = nil
        SharedLogger.info("Connecting... mode=\(configuration.transportMode.rawValue), peer=\(configuration.peerAddr), listen=\(configuration.listenAddr), n=\(configuration.nValue)")
        if configuration.transportMode == .wdtt {
            SharedLogger.info("WDTT start config: vkLinkLen=\(configuration.vkLink.count), passwordSet=\(!configuration.wdttPassword.isEmpty), primaryHashLen=\(configuration.wdttClientKey.count), extraHashesLen=\(configuration.wdttServerKey.count)")
        }

        let currentAppBundleId = Bundle.main.bundleIdentifier ?? "com.prodject.vbridge"
        let providerBundleIdentifier = VBridgeTunnelManagerStore.providerBundleIdentifier
        SharedLogger.debug("Packet tunnel provider id: app=\(currentAppBundleId), provider=\(providerBundleIdentifier)")

        managerStore.load { loadedManager in
            let preExistingTunnelManager = loadedManager
            let tunnelManager = preExistingTunnelManager ?? NETunnelProviderManager()
            SharedLogger.debug("Using \(preExistingTunnelManager != nil ? "existing" : "new") tunnel manager")

            let protocolConfiguration = NETunnelProviderProtocol()
            protocolConfiguration.providerBundleIdentifier = providerBundleIdentifier
            // Match the stable reference startup flow: use the already
            // resolved TURN relay as NE's server address when available.
            // iOS treats this address specially while bringing the provider
            // up, so pointing it at the actual bootstrap relay avoids an
            // unnecessary difference between the saved policy and the first
            // packets emitted by the extension.
            protocolConfiguration.serverAddress = Self.serverHost(
                from: configuration.seededTURN?.address ?? configuration.peerAddr
            )
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

                    self.managerStore.adopt(tunnelManager)

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
        startupRecoveryWorkItem?.cancel()
        startupRecoveryWorkItem = nil
        SharedLogger.info("Disconnecting...")
        let stopManager: (NETunnelProviderManager?) -> Void = { manager in
            guard let manager else {
                SharedLogger.warning("No tunnel manager found")
                return
            }
            switch manager.connection.status {
            case .connected, .connecting, .reasserting:
                SharedLogger.info("Stopping VBridge tunnel session...")
                manager.connection.stopVPNTunnel()
            default:
                SharedLogger.warning("VBridge tunnel not in active state, nothing to stop")
            }
        }
        if let manager = managerStore.manager {
            stopManager(manager)
        } else {
            managerStore.load(completion: stopManager)
        }
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
            SharedLogger.prepareForTunnelProviderLaunch()
            SharedLogger.info("Starting tunnel session... status=\(session.status.rawValue)")
            // Use the same public NEVPNConnection entry point as the stable
            // reference implementation. NETunnelProviderSession.startTunnel
            // ultimately starts the same provider, but keeping the exact
            // save -> reload -> settle -> startVPNTunnel sequence removes a
            // device-dependent lifecycle difference.
            try session.startVPNTunnel()
            scheduleProviderLaunchProbe(session)
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

    private func scheduleProviderLaunchProbe(_ session: NETunnelProviderSession) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            let message = Data("vbridge_provider_probe".utf8)
            do {
                try session.sendProviderMessage(message) { response in
                    DispatchQueue.main.async {
                        guard let response,
                              let text = String(data: response, encoding: .utf8),
                              !text.isEmpty else {
                            SharedLogger.warning("Packet tunnel provider probe returned no response")
                            return
                        }
                        SharedLogger.info("Packet tunnel provider probe: \(text)")
                    }
                }
                SharedLogger.debug("Packet tunnel provider probe requested")
            } catch {
                SharedLogger.error("Packet tunnel provider probe failed: \(error.localizedDescription)")
            }
        }
    }

    private static func serverHost(from address: String) -> String {
        if address.hasPrefix("["), let closingBracket = address.firstIndex(of: "]") {
            return String(address[address.index(after: address.startIndex)..<closingBracket])
        }
        let colonCount = address.reduce(into: 0) { count, character in
            if character == ":" { count += 1 }
        }
        if colonCount == 1, let colon = address.lastIndex(of: ":") {
            return String(address[..<colon])
        }
        return address
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

        // The launch marker is shared through the App Group. Re-signed IPA
        // installations may legitimately run the packet tunnel without an
        // accessible App Group (the reference client falls back to os_log in
        // that situation). Without shared storage, a missing marker proves
        // nothing; killing a .connecting session here interrupts a provider
        // that may already be bootstrapping successfully.
        guard SharedLogger.isTunnelProviderLaunchMarkerAvailable else {
            SharedLogger.warning(
                "Tunnel startup recovery disabled: App Group launch marker unavailable"
            )
            return
        }

        startupRecoveryWorkItem?.cancel()
        let recoveryCheck = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let status = session.status
            guard status != .connected else { return }
            guard !SharedLogger.didTunnelProviderStart else {
                SharedLogger.debug(
                    "Tunnel provider launched; skipping startup recovery (status=\(status.rawValue))"
                )
                return
            }
            SharedLogger.warning(
                "Tunnel provider did not launch (status=\(status.rawValue)); recreating VPN manager once"
            )
            if status == .connecting || status == .reasserting || status == .disconnecting {
                session.stopVPNTunnel()
            }

            // Give neagent a moment to release the stale session before its
            // manager is removed from preferences. The recreated start is
            // explicitly marked as a recovery attempt, so this cannot loop.
            let recreate = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.recreateAndStartTunnel(
                    protocolConfiguration: recoveryConfiguration,
                    providerBundleIdentifier: providerBundleIdentifier
                )
            }
            self.startupRecoveryWorkItem = recreate
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: recreate)
        }
        startupRecoveryWorkItem = recoveryCheck
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0, execute: recoveryCheck)
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
                self.managerStore.clear()
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
                        self.managerStore.adopt(manager)
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
    private let helperBaseURL = URL(string: "http://127.0.0.1:41737/v1/tunnel")!

    func start(_ configuration: TunnelStartConfiguration, completionHandler: @escaping (Bool) -> Void) {
#if targetEnvironment(macCatalyst)
        SharedLogger.info("Connecting... mode=\(configuration.transportMode.rawValue), peer=\(configuration.peerAddr), listen=\(configuration.listenAddr), n=\(configuration.nValue)")
        if configuration.transportMode == .wdtt {
            SharedLogger.info("WDTT start config: vkLinkLen=\(configuration.vkLink.count), passwordSet=\(!configuration.wdttPassword.isEmpty), primaryHashLen=\(configuration.wdttClientKey.count), extraHashesLen=\(configuration.wdttServerKey.count)")
        }

        do {
            try post("start", body: configuration, completionHandler: completionHandler)
        } catch {
            SharedLogger.error("macOS privileged helper request failed: \(error.localizedDescription)")
            completionHandler(false)
        }
#else
        completionHandler(false)
#endif
    }

    func stop() {
#if targetEnvironment(macCatalyst)
        do {
            try post("stop", body: EmptyHelperRequest()) { _ in }
        } catch {
            SharedLogger.error("macOS privileged helper stop request failed: \(error.localizedDescription)")
        }
#endif
    }

#if targetEnvironment(macCatalyst)
    private struct EmptyHelperRequest: Encodable {}

    private func post<T: Encodable>(_ path: String, body: T, completionHandler: @escaping (Bool) -> Void) throws {
        let url = helperBaseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = path == "start" ? 180 : 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                SharedLogger.error("macOS privileged helper is not reachable at \(self.helperBaseURL.absoluteString): \(error.localizedDescription). Install VBridge Helper.pkg from the DMG and approve the administrator prompt, then try again.")
                self.complete(onMain: completionHandler, false)
                return
            }

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(statusCode) else {
                let message = data.flatMap { String(data: $0, encoding: .utf8) }?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                SharedLogger.error("macOS privileged helper rejected \(path): HTTP \(statusCode)\(message?.isEmpty == false ? " - \(message!)" : "")")
                self.complete(onMain: completionHandler, false)
                return
            }

            SharedLogger.info("macOS privileged helper \(path) requested")
            self.complete(onMain: completionHandler, true)
        }
        .resume()
    }

    private func complete(onMain completionHandler: @escaping (Bool) -> Void, _ value: Bool) {
        DispatchQueue.main.async {
            completionHandler(value)
        }
    }
#endif
}
