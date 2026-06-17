//
//  Created by nullcstring.
//

import Foundation
import NetworkExtension
import WireGuardKit
import WireGuardKitGo
import os
import Network

let sharedLogger = Logger(subsystem: "com.prodject.vbridge.network-extension", category: "wgtunnel")
private let captchaRequestStorageKey = "captcha.pending.request"
private let captchaRequestDidChangeNotification = CFNotificationName(rawValue: "com.prodject.vbridge.captcha.pending.request.changed" as CFString)
private let captchaRecoveryStorageKey = "captcha.recovery.request"
private let captchaRecoveryDidChangeNotification = CFNotificationName(rawValue: "com.prodject.vbridge.captcha.recovery.request.changed" as CFString)
private let splitTunnelMatchDomainPrefix = "__vbridge_match_domain__:"
private let splitTunnelDisableGlobalDNSPrefix = "__vbridge_disable_global_dns__"

private struct CaptchaRecoveryRequest: Codable {
    let id: String
    let reason: String
    let createdAt: TimeInterval
}

private let goProxyCaptchaCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void = { _, messageCStr in
    guard let messageCStr else { return }
    let payload = String(cString: messageCStr)
    guard let payloadData = payload.data(using: .utf8) else { return }
    guard let groupID = SharedLogger.appGroupID,
          let defaults = UserDefaults(suiteName: groupID) else {
        sharedLogger.error("[TP]: unable to access shared defaults for captcha payload")
        return
    }

    defaults.set(payloadData, forKey: captchaRequestStorageKey)
    defaults.synchronize()
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        captchaRequestDidChangeNotification,
        nil,
        nil,
        true
    )
    sharedLogger.log("[TP]: captcha payload published for app UI")
}

private func clearCaptchaRequest() {
    guard let groupID = SharedLogger.appGroupID,
          let defaults = UserDefaults(suiteName: groupID) else {
        return
    }

    defaults.removeObject(forKey: captchaRequestStorageKey)
    defaults.synchronize()
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        captchaRequestDidChangeNotification,
        nil,
        nil,
        true
    )
}

private func storeCaptchaRecoveryRequest(reason: String) {
    guard let groupID = SharedLogger.appGroupID,
          let defaults = UserDefaults(suiteName: groupID) else {
        return
    }

    let request = CaptchaRecoveryRequest(
        id: UUID().uuidString,
        reason: reason,
        createdAt: Date().timeIntervalSince1970
    )
    guard let payloadData = try? JSONEncoder().encode(request) else {
        return
    }

    defaults.set(payloadData, forKey: captchaRecoveryStorageKey)
    defaults.synchronize()
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        captchaRecoveryDidChangeNotification,
        nil,
        nil,
        true
    )
    sharedLogger.log("[TP]: captcha recovery request published for app UI")
}

private func clearCaptchaRecoveryRequest() {
    guard let groupID = SharedLogger.appGroupID,
          let defaults = UserDefaults(suiteName: groupID) else {
        return
    }

    defaults.removeObject(forKey: captchaRecoveryStorageKey)
    defaults.synchronize()
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        captchaRecoveryDidChangeNotification,
        nil,
        nil,
        true
    )
}

enum PacketTunnelProviderError: String, Error {
    case invalidProtocolConfiguration
    case cantParseWgQuickConfig
}

private enum SplitTunnelMode: String {
    case direct
    case tunnel
}

private struct SplitTunnelConfiguration {
    let enabled: Bool
    let mode: SplitTunnelMode
    let rules: [String]
}

private struct CompiledSplitTunnelRules {
    var ipRanges: [IPAddressRange]
    var exactDomains: [String]
    var wildcardDomains: [String]
    var ignoredRules: [String]
}

private let goProxyCLoggerCallback: @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?) -> Void = { context, level, messageCStr in
    guard let cStr = messageCStr else { return }
    let message = String(cString: cStr).trimmingCharacters(in: .newlines)

    let shouldRequestCaptchaRecovery =
        message.contains("captcha failed after") ||
        message.contains("manual captcha proxy solve error") ||
        message.contains("manual captcha image solve error") ||
        message.contains("manual captcha timed out") ||
        message.contains("Fatal manual captcha error")

    if shouldRequestCaptchaRecovery {
        storeCaptchaRecoveryRequest(reason: message)
    }

    if level == 1 {
        sharedLogger.error("[TP]: \(message, privacy: .public)")
        SharedLogger.error(message, source: .tunnel)
    } else {
        sharedLogger.log("[TP]: \(message, privacy: .public)")
        SharedLogger.info(message, source: .tunnel)
    }
}

class PacketTunnelProvider: NEPacketTunnelProvider {
    private var vbridgeTunnelHandle: Int32 = -1

	    private lazy var adapter: WireGuardAdapter = {
        return WireGuardAdapter(with: self) { [weak self] _, message in
            sharedLogger.log("[WG]: \(message, privacy: .public)")
            SharedLogger.info(message, source: .wireguard)
        }
	    }()

    private func usesAmneziaObfuscation(_ tunnelConfiguration: TunnelConfiguration) -> Bool {
        let interface = tunnelConfiguration.interface
        return interface.junkPacketCount != nil
            || interface.junkPacketMinSize != nil
            || interface.junkPacketMaxSize != nil
            || interface.initPacketJunkSize != nil
            || interface.responsePacketJunkSize != nil
            || interface.cookieReplyPacketJunkSize != nil
            || interface.transportPacketJunkSize != nil
            || interface.initPacketMagicHeader != nil
            || interface.responsePacketMagicHeader != nil
            || interface.underloadPacketMagicHeader != nil
            || interface.transportPacketMagicHeader != nil
            || interface.specialJunk1 != nil
            || interface.specialJunk2 != nil
            || interface.specialJunk3 != nil
            || interface.specialJunk4 != nil
            || interface.specialJunk5 != nil
    }

    private func splitTunnelConfiguration(from providerConfiguration: [String: Any]) -> SplitTunnelConfiguration {
        if let groupID = SharedLogger.appGroupID,
           let defaults = UserDefaults(suiteName: groupID) {
            let enabled = defaults.object(forKey: "splitTunnelEnabled") as? Bool ?? false
            let mode = SplitTunnelMode(rawValue: defaults.string(forKey: "splitTunnelMode") ?? "") ?? .direct
            let rules = defaults.stringArray(forKey: "splitTunnelRules") ?? []
            if enabled || !rules.isEmpty || defaults.string(forKey: "splitTunnelMode") != nil {
                return SplitTunnelConfiguration(enabled: enabled, mode: mode, rules: rules)
            }
        }

        let enabled = (providerConfiguration["splitTunnelEnabled"] as? Bool) ?? false
        let mode = SplitTunnelMode(rawValue: (providerConfiguration["splitTunnelMode"] as? String) ?? "") ?? .direct
        let rules = (providerConfiguration["splitTunnelRules"] as? [String]) ?? []
        return SplitTunnelConfiguration(enabled: enabled, mode: mode, rules: rules)
    }

    private func applySplitTunnelConfiguration(_ splitTunnel: SplitTunnelConfiguration, to tunnelConfiguration: TunnelConfiguration) {
        guard splitTunnel.enabled, !splitTunnel.rules.isEmpty else { return }

        let compiled = compileSplitTunnelRules(splitTunnel.rules)
        let resolvedDomainRanges = resolveRanges(forDomains: compiled.exactDomains)
        let concreteRanges = deduplicatedRanges(compiled.ipRanges + resolvedDomainRanges)

        let runtimeMatchDomains = deduplicatedStrings(
            compiled.exactDomains + compiled.wildcardDomains.map { String($0.dropFirst(2)) }
        )

        if splitTunnel.mode == .direct {
            if !runtimeMatchDomains.isEmpty {
                tunnelConfiguration.interface.dnsSearch = deduplicatedStrings(
                    tunnelConfiguration.interface.dnsSearch + [splitTunnelDisableGlobalDNSPrefix]
                )
            }
            for index in tunnelConfiguration.peers.indices {
                tunnelConfiguration.peers[index].excludeIPs = deduplicatedRanges(
                    tunnelConfiguration.peers[index].excludeIPs + concreteRanges
                )
            }
        } else {
            let dnsRanges = tunnelConfiguration.interface.dns.compactMap {
                IPAddressRange(from: $0.stringRepresentation)
            }
            let tunnelRanges = deduplicatedRanges(concreteRanges + dnsRanges)

            if !runtimeMatchDomains.isEmpty {
                let customDomains = runtimeMatchDomains.map { splitTunnelMatchDomainPrefix + $0 }
                tunnelConfiguration.interface.dnsSearch = deduplicatedStrings(
                    tunnelConfiguration.interface.dnsSearch + customDomains
                )
            }

            if !tunnelRanges.isEmpty {
                for index in tunnelConfiguration.peers.indices {
                    tunnelConfiguration.peers[index].allowedIPs = tunnelRanges
                }
            }
        }

        if !compiled.ignoredRules.isEmpty {
            SharedLogger.warning(
                "Split tunneling ignored unsupported rules: \(compiled.ignoredRules.joined(separator: ", "))",
                source: .tunnel
            )
        }

        if !compiled.wildcardDomains.isEmpty {
            SharedLogger.warning(
                "Wildcard domain rules are best-effort. DNS matching is applied, but IP routes are only created for explicit IP/CIDR and exact domains.",
                source: .tunnel
            )
        }

        SharedLogger.info(
            "Split tunneling active mode=\(splitTunnel.mode.rawValue) rules=\(splitTunnel.rules.count) concreteRoutes=\(concreteRanges.count) exactDomains=\(compiled.exactDomains.count) wildcardDomains=\(compiled.wildcardDomains.count)",
            source: .tunnel
        )
    }

    private func compileSplitTunnelRules(_ rawRules: [String]) -> CompiledSplitTunnelRules {
        var ipRanges: [IPAddressRange] = []
        var exactDomains: [String] = []
        var wildcardDomains: [String] = []
        var ignoredRules: [String] = []

        for rawRule in rawRules {
            let rule = rawRule.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rule.isEmpty else { continue }

            if let range = IPAddressRange(from: rule) {
                ipRanges.append(range)
                continue
            }

            let lowered = rule.lowercased()
            if lowered.hasPrefix("*.") {
                let suffix = String(lowered.dropFirst(2))
                if isValidWildcardSuffix(suffix) {
                    wildcardDomains.append("*.\(suffix)")
                } else {
                    ignoredRules.append(rule)
                }
                continue
            }

            if isValidDomain(lowered) {
                exactDomains.append(lowered)
                continue
            }

            ignoredRules.append(rule)
        }

        return CompiledSplitTunnelRules(
            ipRanges: deduplicatedRanges(ipRanges),
            exactDomains: deduplicatedStrings(exactDomains),
            wildcardDomains: deduplicatedStrings(wildcardDomains),
            ignoredRules: deduplicatedStrings(ignoredRules)
        )
    }

    private func resolveRanges(forDomains domains: [String]) -> [IPAddressRange] {
        guard !domains.isEmpty else { return [] }

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 12

        let lock = NSLock()
        var results: [IPAddressRange] = []

        for domain in domains {
            queue.addOperation {
                let resolved = self.resolveDomain(domain)
                guard !resolved.isEmpty else { return }
                lock.lock()
                results.append(contentsOf: resolved)
                lock.unlock()
            }
        }

        queue.waitUntilAllOperationsAreFinished()
        return deduplicatedRanges(results)
    }

    private func resolveDomain(_ domain: String) -> [IPAddressRange] {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )

        var infoPointer: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(domain, nil, &hints, &infoPointer)
        guard status == 0, let firstInfo = infoPointer else {
            SharedLogger.warning("Split tunnel DNS resolve failed for \(domain)", source: .tunnel)
            return []
        }
        defer { freeaddrinfo(firstInfo) }

        var ranges: [IPAddressRange] = []
        var pointer: UnsafeMutablePointer<addrinfo>? = firstInfo

        while let info = pointer {
            let family = info.pointee.ai_family
            if family == AF_INET, let sockaddr = info.pointee.ai_addr {
                var address = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil,
                   let range = IPAddressRange(from: String(cString: buffer)) {
                    ranges.append(range)
                }
            } else if family == AF_INET6, let sockaddr = info.pointee.ai_addr {
                var address = sockaddr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                if inet_ntop(AF_INET6, &address, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil,
                   let range = IPAddressRange(from: String(cString: buffer)) {
                    ranges.append(range)
                }
            }
            pointer = info.pointee.ai_next
        }

        return deduplicatedRanges(ranges)
    }

    private func deduplicatedRanges(_ ranges: [IPAddressRange]) -> [IPAddressRange] {
        var seen = Set<IPAddressRange>()
        var deduplicated: [IPAddressRange] = []
        for range in ranges where !seen.contains(range) {
            seen.insert(range)
            deduplicated.append(range)
        }
        return deduplicated
    }

    private func deduplicatedStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var deduplicated: [String] = []
        for value in values where !seen.contains(value) {
            seen.insert(value)
            deduplicated.append(value)
        }
        return deduplicated
    }

    private func isValidDomain(_ value: String) -> Bool {
        guard value.contains("."), !value.hasPrefix("."), !value.hasSuffix(".") else {
            return false
        }

        let labels = value.split(separator: ".")
        guard labels.count >= 2 else { return false }

        for label in labels {
            guard !label.isEmpty, label.count <= 63 else { return false }
            guard label.first != "-", label.last != "-" else { return false }
            let isValid = label.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-"
            }
            guard isValid else { return false }
        }

        return true
    }

    private func isValidWildcardSuffix(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("."), !value.hasSuffix(".") else {
            return false
        }

        let labels = value.split(separator: ".")
        guard !labels.isEmpty else { return false }

        for label in labels {
            guard !label.isEmpty, label.count <= 63 else { return false }
            guard label.first != "-", label.last != "-" else { return false }
            let isValid = label.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-"
            }
            guard isValid else { return false }
        }

        return true
    }

    
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        sharedLogger.log("=== Starting tunnel ===")
        SharedLogger.info("Starting tunnel", source: .tunnel)
        clearCaptchaRecoveryRequest()

        guard let protocolConfiguration = self.protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfiguration = protocolConfiguration.providerConfiguration else {
            sharedLogger.error("Invalid provider configuration")
            SharedLogger.error("Invalid provider configuration", source: .tunnel)
            completionHandler(PacketTunnelProviderError.invalidProtocolConfiguration)
            return
        }

        let transportMode = (providerConfiguration["transportMode"] as? String) ?? "wg"
        let isWDTT = transportMode == "wdtt"
        var tunnelConfiguration: TunnelConfiguration?
        var wgUAPI = ""

        if !isWDTT {
            guard let wgQuickConfig = providerConfiguration["wgQuickConfig"] as? String else {
                sharedLogger.error("wgQuickConfig missing from provider configuration")
                SharedLogger.error("WireGuard config missing from provider configuration", source: .wireguard)
                completionHandler(PacketTunnelProviderError.cantParseWgQuickConfig)
                return
            }

            do {
                let parsedConfiguration = try TunnelConfiguration(fromWgQuickConfig: wgQuickConfig)
                let splitTunnel = splitTunnelConfiguration(from: providerConfiguration)
                applySplitTunnelConfiguration(splitTunnel, to: parsedConfiguration)
                tunnelConfiguration = parsedConfiguration
                wgUAPI = PacketTunnelSettingsGenerator(
                    tunnelConfiguration: parsedConfiguration,
                    resolvedEndpoints: parsedConfiguration.peers.map(\.endpoint)
                ).uapiConfigurationString()
            } catch {
                sharedLogger.error("wg-quick config parse error: \(error.localizedDescription)")
                SharedLogger.error("Failed to parse WireGuard config: \(error.localizedDescription)", source: .wireguard)
                completionHandler(PacketTunnelProviderError.cantParseWgQuickConfig)
                return
            }
        }

        guard let peerAddr = providerConfiguration["peerAddr"] as? String,
              let nValueInt = providerConfiguration["nValue"] as? Int else {
            sharedLogger.error("Missing proxy parameters in configuration")
            SharedLogger.error("Missing proxy parameters in configuration", source: .tunnel)
            completionHandler(PacketTunnelProviderError.invalidProtocolConfiguration)
            return
        }
        let requestedNValue = Int32(nValueInt)
        let useSingleProxyWorker = tunnelConfiguration.map(usesAmneziaObfuscation) ?? false
        let nValue = useSingleProxyWorker ? Int32(1) : requestedNValue
        let turnHost = (providerConfiguration["turnHost"] as? String) ?? ""
        let turnPort = (providerConfiguration["turnPort"] as? String) ?? ""
        let useUdp = (providerConfiguration["useUdp"] as? Bool) ?? true
        let vkLink = (providerConfiguration["vkLink"] as? String) ?? ""
        let wrapKeyHex = (providerConfiguration["wrapKeyHex"] as? String) ?? ""
        let wdttPassword = (providerConfiguration["wdttPassword"] as? String) ?? ""

        if useSingleProxyWorker && requestedNValue != 1 {
            SharedLogger.warning(
                "Amnezia obfuscation detected; forcing a single proxy connection to preserve handshake packet order",
                source: .tunnel
            )
        }
        SharedLogger.info("Peer: \(peerAddr), Mode: \(transportMode), N: \(nValue), TURN override: \(turnHost.isEmpty ? "auto" : turnHost):\(turnPort.isEmpty ? "auto" : turnPort), UDP: \(useUdp)", source: .tunnel)

        guard let proxyConfigJSON = makeAntonProxyConfigJSON(
            mode: transportMode,
            vkLink: vkLink,
            peerAddr: peerAddr,
            turnHost: turnHost,
            turnPort: turnPort,
            useUdp: useUdp,
            nValue: Int(nValue),
            wrapKeyHex: wrapKeyHex,
            wdttPassword: wdttPassword
        ) else {
            SharedLogger.error("Failed to encode proxy config", source: .tunnel)
            completionHandler(PacketTunnelProviderError.invalidProtocolConfiguration)
            return
        }

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { return }
            let handle = proxyConfigJSON.withCString {
                VBridgeWGStartVKBootstrap(UnsafeMutablePointer(mutating: $0))
            }
            guard handle >= 0 else {
                SharedLogger.error("VBridgeWGStartVKBootstrap failed: \(handle)", source: .tunnel)
                completionHandler(PacketTunnelProviderError.invalidProtocolConfiguration)
                return
            }
            self.vbridgeTunnelHandle = handle

            var networkSettings: NEPacketTunnelNetworkSettings
            var effectiveUAPI = wgUAPI

            if isWDTT {
                guard let provisionJSON = self.waitForWrapAProvision(handle: handle, timeoutMs: 120000),
                      let provision = try? JSONDecoder().decode(WrapAProvision.self, from: Data(provisionJSON.utf8)),
                      !provision.uapi.isEmpty else {
                    VBridgeWGTurnOff(handle)
                    self.vbridgeTunnelHandle = -1
                    SharedLogger.error("WDTT provision failed", source: .tunnel)
                    completionHandler(PacketTunnelProviderError.invalidProtocolConfiguration)
                    return
                }
                effectiveUAPI = provision.uapi
                networkSettings = self.createTunnelSettings(
                    address: provision.address,
                    dns: provision.dns,
                    mtu: provision.mtu.map(String.init) ?? "1280",
                    tunnelRemoteAddress: peerAddr.components(separatedBy: ":").first ?? "127.0.0.1"
                )
            } else if let tunnelConfiguration = tunnelConfiguration {
                let ready = VBridgeWGWaitBootstrapReady(handle, 120000)
                guard ready == 1 else {
                    VBridgeWGTurnOff(handle)
                    self.vbridgeTunnelHandle = -1
                    SharedLogger.error("VK/TURN bootstrap failed: \(ready)", source: .tunnel)
                    completionHandler(PacketTunnelProviderError.invalidProtocolConfiguration)
                    return
                }

                networkSettings = PacketTunnelSettingsGenerator(
                    tunnelConfiguration: tunnelConfiguration,
                    resolvedEndpoints: tunnelConfiguration.peers.map(\.endpoint)
                ).generateNetworkSettings()
            } else {
                VBridgeWGTurnOff(handle)
                self.vbridgeTunnelHandle = -1
                completionHandler(PacketTunnelProviderError.cantParseWgQuickConfig)
                return
            }

            self.setTunnelNetworkSettings(networkSettings) { error in
                if let error = error {
                    VBridgeWGTurnOff(handle)
                    self.vbridgeTunnelHandle = -1
                    completionHandler(error)
                    return
                }

                guard let tunFd = self.findTunFileDescriptor() else {
                    VBridgeWGTurnOff(handle)
                    self.vbridgeTunnelHandle = -1
                    SharedLogger.error("Could not find TUN file descriptor", source: .wireguard)
                    completionHandler(PacketTunnelProviderError.invalidProtocolConfiguration)
                    return
                }

                let attachResult = effectiveUAPI.withCString {
                    VBridgeWGAttachWireGuard(handle, UnsafeMutablePointer(mutating: $0), tunFd)
                }
                guard attachResult == 1 else {
                    VBridgeWGTurnOff(handle)
                    self.vbridgeTunnelHandle = -1
                    SharedLogger.error("VBridgeWGAttachWireGuard failed: \(attachResult)", source: .wireguard)
                    completionHandler(PacketTunnelProviderError.invalidProtocolConfiguration)
                    return
                }
                SharedLogger.info("Tunnel up with anton48 runtime", source: .wireguard)
                completionHandler(nil)
            }
        }
    }

    private struct WrapAProvision: Decodable {
        let address: String
        let dns: String
        let mtu: Int?
        let uapi: String
    }

    private func makeAntonProxyConfigJSON(
        mode: String,
        vkLink: String,
        peerAddr: String,
        turnHost: String,
        turnPort: String,
        useUdp: Bool,
        nValue: Int,
        wrapKeyHex: String,
        wdttPassword: String
    ) -> String? {
        let useWDTT = mode == "wdtt"
        let useSRTPCommunity = mode == "srtpCommunity"
        let payload: [String: Any] = [
            "vk_link": vkLink,
            "peer_addr": peerAddr,
            "turn_server": turnHost,
            "turn_port": turnPort,
            "use_dtls": !useWDTT,
            "use_udp": useUdp,
            "use_wrap": useSRTPCommunity,
            "wrap_key_hex": wrapKeyHex,
            "use_srtp": false,
            "use_wrap_a": useWDTT,
            "wrap_a_password": wdttPassword,
            "device_id": persistedDeviceID(),
            "num_conns": max(nValue, 1),
            "cred_pool_cooldown_seconds": 120
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    private func persistedDeviceID() -> String {
        let key = "wdtt.device.id"
        if let groupID = SharedLogger.appGroupID,
           let defaults = UserDefaults(suiteName: groupID) {
            if let existing = defaults.string(forKey: key), !existing.isEmpty {
                return existing
            }
            let value = UUID().uuidString
            defaults.set(value, forKey: key)
            defaults.synchronize()
            return value
        }
        return UUID().uuidString
    }

    private func waitForWrapAProvision(handle: Int32, timeoutMs: Int32) -> String? {
        guard let pointer = VBridgeWGWaitWrapAProvision(handle, timeoutMs) else {
            return nil
        }
        defer { free(UnsafeMutableRawPointer(pointer)) }
        let json = String(cString: pointer)
        return json.isEmpty ? nil : json
    }

    private func createTunnelSettings(
        address: String,
        dns: String,
        mtu: String,
        tunnelRemoteAddress: String
    ) -> NEPacketTunnelNetworkSettings {
        let parts = address.split(separator: "/", maxSplits: 1).map(String.init)
        let ip = parts.first ?? "192.168.102.3"
        let prefix = parts.count > 1 ? (Int(parts[1]) ?? 24) : 24
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunnelRemoteAddress)
        let ipv4 = NEIPv4Settings(addresses: [ip], subnetMasks: [prefixToSubnet(prefix)])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        let dnsServers = dns
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !dnsServers.isEmpty {
            let dnsSettings = NEDNSSettings(servers: dnsServers)
            dnsSettings.matchDomains = [""]
            settings.dnsSettings = dnsSettings
        }

        if let mtuValue = Int(mtu), mtuValue > 0 {
            settings.mtu = NSNumber(value: mtuValue)
        } else {
            settings.mtu = NSNumber(value: 1280)
        }
        return settings
    }

    private func prefixToSubnet(_ prefix: Int) -> String {
        let clamped = min(max(prefix, 0), 32)
        var mask: UInt32 = 0
        for i in 0..<clamped {
            mask |= (1 << (31 - i))
        }
        return "\(mask >> 24).\((mask >> 16) & 0xFF).\((mask >> 8) & 0xFF).\(mask & 0xFF)"
    }

    private func findTunFileDescriptor() -> Int32? {
        var buffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        for fd: Int32 in 0...1024 {
            var length = socklen_t(buffer.count)
            if getsockopt(fd, 2, 2, &buffer, &length) == 0 {
                let name = String(cString: buffer)
                if name.hasPrefix("utun") {
                    return fd
                }
            }
        }
        return nil
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        sharedLogger.log("Stopping tunnel")
        SharedLogger.info("Stopping tunnel (reason: \(reason.rawValue))", source: .tunnel)

        if vbridgeTunnelHandle >= 0 {
            VBridgeWGTurnOff(vbridgeTunnelHandle)
            vbridgeTunnelHandle = -1
            SharedLogger.info("anton48 runtime stopped", source: .tunnel)
            clearCaptchaRequest()
            clearCaptchaRecoveryRequest()
            SharedLogger.info("Tunnel stopped", source: .tunnel)
            completionHandler()
            return
        } else {
            StopProxy()
            SharedLogger.info("TURN proxy stopped", source: .tunnel)
        }
        clearCaptchaRequest()
        clearCaptchaRecoveryRequest()

        adapter.stop { [weak self] error in
            guard self != nil else { return }
            if let error = error {
                sharedLogger.error("Failed to stop WireGuard adapter: \(error.localizedDescription)")
                SharedLogger.error("WireGuard adapter stop failed: \(error.localizedDescription)", source: .wireguard)
            } else {
                SharedLogger.info("WireGuard adapter stopped", source: .wireguard)
            }
            SharedLogger.info("Tunnel stopped", source: .tunnel)
            completionHandler()

            #if os(macOS)
            // HACK: We have to kill the tunnel process ourselves because of a macOS bug
            exit(0)
            #endif
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard let completionHandler = completionHandler else { return }

        sharedLogger.log("handleAppMessage: received \(messageData.count) bytes")
        if messageData.count == 1, messageData[0] == 0 {
            sharedLogger.log("handleAppMessage: runtime configuration requested")
            if vbridgeTunnelHandle >= 0, let pointer = VBridgeWGGetConfig(vbridgeTunnelHandle) {
                defer { free(UnsafeMutableRawPointer(pointer)) }
                let settings = String(cString: pointer)
                completionHandler(settings.data(using: .utf8))
                return
            }
            adapter.getRuntimeConfiguration { settings in
                var data: Data?
                if let settings = settings {
                    data = settings.data(using: .utf8)
                } else {
                    sharedLogger.log("handleAppMessage: runtime configuration unavailable")
                }
                completionHandler(data)
            }
        } else {
            sharedLogger.log("handleAppMessage: unsupported message payload")
            completionHandler(nil)
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        // Add code here to get ready to sleep.
        completionHandler()
    }

    override func wake() {
        // Add code here to wake up.
    }
}
