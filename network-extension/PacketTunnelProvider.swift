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
private let splitTunnelMatchDomainPrefix = "__vbridge_match_domain__:"
private let splitTunnelDisableGlobalDNSPrefix = "__vbridge_disable_global_dns__"

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

    if level == 1 {
        sharedLogger.error("[TP]: \(message, privacy: .public)")
        SharedLogger.error(message, source: .tunnel)
    } else {
        sharedLogger.log("[TP]: \(message, privacy: .public)")
        SharedLogger.info(message, source: .tunnel)
    }
}

class PacketTunnelProvider: NEPacketTunnelProvider {

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

        guard let protocolConfiguration = self.protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfiguration = protocolConfiguration.providerConfiguration else {
            sharedLogger.error("Invalid provider configuration")
            SharedLogger.error("Invalid provider configuration", source: .tunnel)
            completionHandler(PacketTunnelProviderError.invalidProtocolConfiguration)
            return
        }

        guard let wgQuickConfig = providerConfiguration["wgQuickConfig"] as? String else {
            sharedLogger.error("wgQuickConfig missing from provider configuration")
            SharedLogger.error("WireGuard config missing from provider configuration", source: .wireguard)
            completionHandler(PacketTunnelProviderError.cantParseWgQuickConfig)
            return
        }

        let tunnelConfiguration: TunnelConfiguration
        do {
            tunnelConfiguration = try TunnelConfiguration(fromWgQuickConfig: wgQuickConfig)
        } catch {
            sharedLogger.error("wg-quick config parse error: \(error.localizedDescription)")
            SharedLogger.error("Failed to parse WireGuard config: \(error.localizedDescription)", source: .wireguard)
            completionHandler(PacketTunnelProviderError.cantParseWgQuickConfig)
            return
        }

        let splitTunnel = splitTunnelConfiguration(from: providerConfiguration)
        applySplitTunnelConfiguration(splitTunnel, to: tunnelConfiguration)

        guard let vkLink = providerConfiguration["vkLink"] as? String,
              let peerAddr = providerConfiguration["peerAddr"] as? String,
              let listenAddr = providerConfiguration["listenAddr"] as? String,
              let nValueInt = providerConfiguration["nValue"] as? Int else {
            sharedLogger.error("Missing proxy parameters in configuration")
            SharedLogger.error("Missing proxy parameters in configuration", source: .tunnel)
            completionHandler(PacketTunnelProviderError.invalidProtocolConfiguration)
            return
        }
        let requestedNValue = Int32(nValueInt)
        let credsGroupSize = Int32(max((providerConfiguration["credsGroupSize"] as? Int) ?? 12, 1))
        let useSingleProxyWorker = usesAmneziaObfuscation(tunnelConfiguration)
        let nValue = useSingleProxyWorker ? Int32(1) : requestedNValue
        let manualCaptcha = (providerConfiguration["manualCaptcha"] as? Bool) ?? false
        let turnHost = (providerConfiguration["turnHost"] as? String) ?? ""
        let turnPort = (providerConfiguration["turnPort"] as? String) ?? ""
        let useUdp = (providerConfiguration["useUdp"] as? Bool) ?? true

        if useSingleProxyWorker && requestedNValue != 1 {
            SharedLogger.warning(
                "Amnezia obfuscation detected; forcing a single proxy connection to preserve handshake packet order",
                source: .tunnel
            )
        }
        SharedLogger.info("Peer: \(peerAddr), Listen: \(listenAddr), N: \(nValue), Workers/Identity: \(credsGroupSize), ManualCaptcha: \(manualCaptcha), TURN override: \(turnHost.isEmpty ? "auto" : turnHost):\(turnPort.isEmpty ? "auto" : turnPort), UDP: \(useUdp)", source: .tunnel)
        SharedLogger.info("Starting TURN proxy...", source: .tunnel)

        ProxySetLogger(nil, goProxyCLoggerCallback)
        ProxySetCaptchaCallback(nil, goProxyCaptchaCallback)

        DispatchQueue.global(qos: .userInteractive).async {
            StartProxy(vkLink, peerAddr, listenAddr, nValue, credsGroupSize, manualCaptcha ? 1 : 0, turnHost, turnPort, useUdp ? 1 : 0)
        }

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let ready = ProxyWaitReady(120000)
            guard let self = self else { return }

            if ready == 0 {
                StopProxy()
                sharedLogger.error("TURN proxy failed before DTLS became ready")
                SharedLogger.error("TURN proxy startup failed before DTLS became ready", source: .tunnel)
                completionHandler(PacketTunnelProviderError.invalidProtocolConfiguration)
                return
            }

            SharedLogger.info("DTLS ready, starting WireGuard adapter...", source: .tunnel)
            self.adapter.start(tunnelConfiguration: tunnelConfiguration) { [weak self] adapterError in
                guard let self = self else { return }
                if let adapterError = adapterError {
                    sharedLogger.error("WireGuard adapter error: \(adapterError.localizedDescription)")
                    SharedLogger.error("WireGuard adapter failed: \(adapterError.localizedDescription)", source: .wireguard)
                } else {
                    let interfaceName = self.adapter.interfaceName ?? "unknown"
                    sharedLogger.log("Tunnel interface is \(interfaceName)")
                    SharedLogger.info("Tunnel up on interface \(interfaceName)", source: .wireguard)
                }
                completionHandler(adapterError)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        sharedLogger.log("Stopping tunnel")
        SharedLogger.info("Stopping tunnel (reason: \(reason.rawValue))", source: .tunnel)

        StopProxy()
        SharedLogger.info("TURN proxy stopped", source: .tunnel)
        clearCaptchaRequest()

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
