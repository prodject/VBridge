//
//  Created by nullcstring.
//

import Foundation
import NetworkExtension
import WireGuardKit
import WireGuardKitGo
import os
import Network
import Darwin

let sharedLogger = Logger(subsystem: "com.prodject.vbridge.network-extension", category: "wgtunnel")
private let captchaRequestStorageKey = "captcha.pending.request"
private let captchaRequestDidChangeNotification = CFNotificationName(rawValue: "com.prodject.vbridge.captcha.pending.request.changed" as CFString)
private let captchaRecoveryStorageKey = "captcha.recovery.request"
private let captchaRecoveryDidChangeNotification = CFNotificationName(rawValue: "com.prodject.vbridge.captcha.recovery.request.changed" as CFString)
private let splitTunnelMatchDomainPrefix = "__vbridge_match_domain__:"
private let splitTunnelDisableGlobalDNSPrefix = "__vbridge_disable_global_dns__"
private let splitTunnelSynchronousDomainLimit = 64
private let splitTunnelMetadataFileName = "split-tunnel-metadata.json"
private let splitTunnelRulesFileName = "split-tunnel-rules.txt"
private let goRuntimeMemoryLimit = "24MiB"
private let packetTunnelBuildMarker = "PT_BUILD_2026_08_26_A"
private let tunnelLogExportMessage = "vbridge_export_tunnel_log"

private func sharedDefaultsForTunnel() -> UserDefaults? {
    guard let groupID = SharedLogger.appGroupID else {
        return nil
    }
    return UserDefaults(suiteName: groupID)
}

private func configureGoRuntimeMemoryBeforeFirstCall() {
    setenv("GOMEMLIMIT", goRuntimeMemoryLimit, 1)
    setenv("GOGC", "25", 1)
    setenv("GODEBUG", "asyncpreemptoff=1,madvdontneed=1", 1)
    NSLog("Go runtime env configured: GOMEMLIMIT=\(goRuntimeMemoryLimit), GOGC=25")
}

private func extensionDocumentsLogURL() -> URL? {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
        .appendingPathComponent("vpn_tunnel.log")
}

private struct CaptchaRecoveryRequest: Codable {
    let id: String
    let reason: String
    let createdAt: TimeInterval
}

private let goProxyCaptchaCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void = { _, messageCStr in
    guard let messageCStr else { return }
    let payload = String(cString: messageCStr)
    guard let payloadData = payload.data(using: .utf8) else { return }
    guard let defaults = sharedDefaultsForTunnel() else {
        sharedLogger.error("[TP]: shared defaults unavailable for captcha payload; degraded build cannot hand captcha to app UI")
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
    guard let defaults = sharedDefaultsForTunnel() else {
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
    guard let defaults = sharedDefaultsForTunnel() else {
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
    guard let defaults = sharedDefaultsForTunnel() else {
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

private struct SplitTunnelMetadata: Decodable {
    let enabled: Bool
    let mode: String
    let ruleCount: Int
}

private struct CompiledSplitTunnelRules {
    var ipRanges: [IPAddressRange]
    var exactDomains: [String]
    var wildcardDomains: [String]
    var ignoredRules: [String]
}

private func publishGoProxyLog(level: Int32, message: String) {
    let lowercasedMessage = message.lowercased()
    let shouldRequestCaptchaRecovery =
        message.contains("captcha failed after") ||
        message.contains("manual captcha proxy solve error") ||
        message.contains("manual captcha image solve error") ||
        message.contains("manual captcha timed out") ||
        message.contains("Fatal manual captcha error")
    let shouldSurfaceConnectionWarning =
        lowercasedMessage.contains("allocation quota reached") ||
        lowercasedMessage.contains("allocate quota error") ||
        lowercasedMessage.contains("error 486") ||
        lowercasedMessage.contains("failed to refresh allocation") ||
        lowercasedMessage.contains("failed to refresh permissions") ||
        lowercasedMessage.contains("all retransmissions failed") ||
        lowercasedMessage.contains("broken pipe") ||
        lowercasedMessage.contains("i/o timeout")

    if shouldRequestCaptchaRecovery {
        storeCaptchaRecoveryRequest(reason: message)
    }

    if level == 1 {
        sharedLogger.error("[TP]: \(message, privacy: .public)")
        SharedLogger.error(message, source: .tunnel)
    } else if shouldSurfaceConnectionWarning {
        sharedLogger.warning("[TP]: \(message, privacy: .public)")
        SharedLogger.warning(message, source: .tunnel)
    } else {
        sharedLogger.log("[TP]: \(message, privacy: .public)")
        SharedLogger.info(message, source: .tunnel)
    }
}

private let goProxyCLoggerCallback: @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?) -> Void = { _, level, messageCStr in
    guard let cStr = messageCStr else { return }
    publishGoProxyLog(level: level, message: String(cString: cStr).trimmingCharacters(in: .newlines))
}

private let vbridgeGoLoggerCallback: @convention(c) (Int32, UnsafePointer<CChar>?) -> Void = { level, messageCStr in
    guard let cStr = messageCStr else { return }
    publishGoProxyLog(level: level, message: String(cString: cStr).trimmingCharacters(in: .newlines))
}

class PacketTunnelProvider: NEPacketTunnelProvider {
    private var vbridgeTunnelHandle: Int32 = -1
    private var activeTransportMode = "wg"
    private var pathMonitor: Network.NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "com.prodject.vbridge.network-extension.path-monitor")
    private var lastObservedPathSummary: String?
    private var didPauseProxyForSleep = false
    private var activeSplitTunnel = SplitTunnelConfiguration(enabled: false, mode: .direct, rules: [])
    private var activeBaseWgQuickConfig = ""
    private var activeProvisionAddress = ""
    private var activeProvisionFallbackDNS = ""
    private var activeProvisionMTU = "1280"
    private var activeTunnelRemoteAddress = "10.0.0.1"

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

    private func splitTunnelConfiguration(
        providerConfiguration: [String: Any]
    ) -> SplitTunnelConfiguration {
        let inlineRules: [String]?
        if let compressedRules = providerConfiguration["splitTunnelRulesLZFSE"] as? Data,
           let decompressedRules = try? (compressedRules as NSData).decompressed(using: .lzfse),
           let rulesText = String(data: decompressedRules as Data, encoding: .utf8) {
            inlineRules = rulesText.components(separatedBy: .newlines).filter { !$0.isEmpty }
        } else {
            // Backward compatibility with the first inline-rules build.
            inlineRules = providerConfiguration["splitTunnelRules"] as? [String]
        }

        if let enabled = providerConfiguration["splitTunnelEnabled"] as? Bool,
           let modeValue = providerConfiguration["splitTunnelMode"] as? String,
           let rules = inlineRules {
            let mode = SplitTunnelMode(rawValue: modeValue) ?? .direct
            SharedLogger.info(
                "Split tunneling configuration received from app: enabled=\(enabled) mode=\(mode.rawValue) rules=\(rules.count)",
                source: .tunnel
            )
            return SplitTunnelConfiguration(
                enabled: enabled && !rules.isEmpty,
                mode: mode,
                rules: rules
            )
        }

        guard let groupID = SharedLogger.appGroupID,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            SharedLogger.warning("Split tunneling disabled: App Group container unavailable", source: .tunnel)
            return SplitTunnelConfiguration(enabled: false, mode: .direct, rules: [])
        }

        let metadataURL = container.appendingPathComponent(splitTunnelMetadataFileName)
        guard let metadataData = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(SplitTunnelMetadata.self, from: metadataData) else {
            return SplitTunnelConfiguration(enabled: false, mode: .direct, rules: [])
        }

        let mode = SplitTunnelMode(rawValue: metadata.mode) ?? .direct
        guard metadata.enabled, metadata.ruleCount > 0 else {
            return SplitTunnelConfiguration(enabled: false, mode: mode, rules: [])
        }

        let rulesURL = container.appendingPathComponent(splitTunnelRulesFileName)
        guard let rulesText = try? String(contentsOf: rulesURL, encoding: .utf8) else {
            SharedLogger.warning("Split tunneling disabled: rules file unavailable", source: .tunnel)
            return SplitTunnelConfiguration(enabled: false, mode: mode, rules: [])
        }

        return SplitTunnelConfiguration(
            enabled: true,
            mode: mode,
            rules: rulesText.components(separatedBy: .newlines).filter { !$0.isEmpty }
        )
    }

    private func rangesResolvedForSplitTunnel(_ compiled: CompiledSplitTunnelRules) -> [IPAddressRange] {
        guard compiled.exactDomains.count <= splitTunnelSynchronousDomainLimit else {
            SharedLogger.warning(
                "Split tunneling skipped eager DNS resolution for large domain list (\(compiled.exactDomains.count) domains, limit=\(splitTunnelSynchronousDomainLimit)); applying IP/CIDR routes and DNS matching only",
                source: .tunnel
            )
            return compiled.ipRanges
        }
        return deduplicatedRanges(compiled.ipRanges + resolveRanges(forDomains: compiled.exactDomains))
    }

    private func applySplitTunnelConfiguration(_ splitTunnel: SplitTunnelConfiguration, to tunnelConfiguration: TunnelConfiguration) {
        guard splitTunnel.enabled, !splitTunnel.rules.isEmpty else { return }

        let compiled = compileSplitTunnelRules(splitTunnel.rules)
        let concreteRanges = rangesResolvedForSplitTunnel(compiled)

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

            if let expandedRanges = ipv4Ranges(from: rule) {
                ipRanges.append(contentsOf: expandedRanges)
                continue
            }

            if let urlHost = hostFromURLRule(rule) {
                if let range = IPAddressRange(from: urlHost) {
                    ipRanges.append(range)
                } else if isValidDomain(urlHost) {
                    exactDomains.append(urlHost)
                } else {
                    ignoredRules.append(rule)
                }
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

    private func hostFromURLRule(_ value: String) -> String? {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            return nil
        }
        return host
    }

    private func ipv4Ranges(from value: String) -> [IPAddressRange]? {
        let separators = ["-", "–", "—"]
        let compact = value.replacingOccurrences(of: " ", with: "")

        for separator in separators where compact.contains(separator) {
            let parts = compact.components(separatedBy: separator)
            guard parts.count == 2,
                  let start = IPv4Address(parts[0]),
                  let end = IPv4Address(parts[1]) else {
                return nil
            }

            let startValue = ipv4NumericValue(start)
            let endValue = ipv4NumericValue(end)
            guard startValue <= endValue else { return nil }
            return cidrRangesCoveringIPv4Range(start: startValue, end: endValue)
        }

        return nil
    }

    private func cidrRangesCoveringIPv4Range(start: UInt32, end: UInt32) -> [IPAddressRange] {
        var ranges: [IPAddressRange] = []
        var current = start

        while current <= end {
            let zeroBits = current == 0 ? 32 : current.trailingZeroBitCount
            var prefix = max(0, 32 - Int(zeroBits))
            var blockSize: UInt64 = 1 << UInt64(32 - prefix)

            while UInt64(current) + blockSize - 1 > UInt64(end) {
                prefix += 1
                blockSize >>= 1
            }

            let cidr = "\(ipv4String(from: current))/\(prefix)"
            if let range = IPAddressRange(from: cidr) {
                ranges.append(range)
            }

            if end - current + 1 <= UInt32(blockSize) {
                break
            }
            current += UInt32(blockSize)
        }

        return ranges
    }

    private func ipv4NumericValue(_ address: IPv4Address) -> UInt32 {
        address.rawValue.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func ipv4String(from value: UInt32) -> String {
        let octets = [
            String((value >> 24) & 0xff),
            String((value >> 16) & 0xff),
            String((value >> 8) & 0xff),
            String(value & 0xff)
        ]
        return octets.joined(separator: ".")
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
        SharedLogger.markTunnelProviderStarted()
        NSLog("START TUNNEL CALLED")
        NSLog("BUILD MARKER %@", packetTunnelBuildMarker)
        configureGoRuntimeMemoryBeforeFirstCall()
        sharedLogger.log("START TUNNEL CALLED")
        sharedLogger.log("BUILD MARKER \(packetTunnelBuildMarker, privacy: .public)")
        SharedLogger.info("START TUNNEL CALLED", source: .tunnel)
        SharedLogger.info("BUILD MARKER \(packetTunnelBuildMarker)", source: .tunnel)
        sharedLogger.log("=== Starting tunnel ===")
        SharedLogger.info("Starting tunnel", source: .tunnel)
        VBridgeWGSetLogger(vbridgeGoLoggerCallback)
        ProxySetCaptchaCallback(nil, goProxyCaptchaCallback)
        VBridgeWGSetTimezoneOffset(Int32(TimeZone.current.secondsFromGMT()))
        if let logPath = SharedLogger.logFileURL?.path {
            logPath.withCString {
                VBridgeWGSetLogFilePath($0)
            }
        }
        clearCaptchaRecoveryRequest()

        guard let protocolConfiguration = self.protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfiguration = protocolConfiguration.providerConfiguration else {
            sharedLogger.error("Invalid provider configuration")
            SharedLogger.error("Invalid provider configuration", source: .tunnel)
            completionHandler(PacketTunnelProviderError.invalidProtocolConfiguration)
            return
        }

        let rawTransportMode = (providerConfiguration["transportMode"] as? String) ?? "nil"
        let rawCSQTTPassword = ((providerConfiguration["csqttPassword"] as? String) ?? "").isEmpty ? "empty" : "set"
        let rawWDTTPPassword = ((providerConfiguration["wdttPassword"] as? String) ?? "").isEmpty ? "empty" : "set"
        NSLog("ProviderConfig: transportMode=%@ csqttPassword=%@ wdttPassword=%@", rawTransportMode, rawCSQTTPassword, rawWDTTPPassword)
        SharedLogger.info(
            "ProviderConfig loaded: transportMode=\(rawTransportMode), csqttPassword=\(rawCSQTTPassword), wdttPassword=\(rawWDTTPPassword)",
            source: .tunnel
        )

        let transportMode = (providerConfiguration["transportMode"] as? String) ?? "wg"
        activeTransportMode = transportMode
        let isWDTT = transportMode == "wdtt"
        let isCSQTT = transportMode == "csqtt"
        let splitTunnel = splitTunnelConfiguration(providerConfiguration: providerConfiguration)
        activeSplitTunnel = splitTunnel
        var tunnelConfiguration: TunnelConfiguration?
        var wgUAPI = ""

        if !isWDTT && !isCSQTT {
            guard let wgQuickConfig = providerConfiguration["wgQuickConfig"] as? String else {
                sharedLogger.error("wgQuickConfig missing from provider configuration")
                SharedLogger.error("WireGuard config missing from provider configuration", source: .wireguard)
                completionHandler(PacketTunnelProviderError.cantParseWgQuickConfig)
                return
            }

            do {
                activeBaseWgQuickConfig = wgQuickConfig
                let parsedConfiguration = try TunnelConfiguration(fromWgQuickConfig: wgQuickConfig)
                let dnsMode = (providerConfiguration["dnsMode"] as? String) ?? "server"
                let dnsPrimary = (providerConfiguration["dnsPrimary"] as? String) ?? ""
                let dnsSecondary = (providerConfiguration["dnsSecondary"] as? String) ?? ""
                applyDNSOverride(mode: dnsMode, primary: dnsPrimary, secondary: dnsSecondary, to: parsedConfiguration)
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
        let listenAddr = (providerConfiguration["listenAddr"] as? String) ?? "127.0.0.1:9000"
        let useUdp = (providerConfiguration["useUdp"] as? Bool) ?? true
        let vkLink = (providerConfiguration["vkLink"] as? String) ?? ""
        let wrapKeyHex = (providerConfiguration["wrapKeyHex"] as? String) ?? ""
        let wdttPassword = (providerConfiguration["wdttPassword"] as? String) ?? ""
        let wdttClientKey = (providerConfiguration["wdttClientKey"] as? String) ?? ""
        let wdttServerKey = (providerConfiguration["wdttServerKey"] as? String) ?? ""
        let wdttFingerprint = (providerConfiguration["wdttFingerprint"] as? String) ?? "auto"
        let wdttClientIDMode = (providerConfiguration["wdttClientIDMode"] as? String) ?? "default"
        let wdttUseVKCallsPreflight = (providerConfiguration["wdttUseVKCallsPreflight"] as? Bool) ?? true
        let wdttTunnelMTU = providerConfiguration["wdttTunnelMTU"] as? Int
        let dnsMode = (providerConfiguration["dnsMode"] as? String) ?? "server"
        let dnsPrimary = (providerConfiguration["dnsPrimary"] as? String) ?? ""
        let dnsSecondary = (providerConfiguration["dnsSecondary"] as? String) ?? ""
        let csqttPassword = (providerConfiguration["csqttPassword"] as? String) ?? ""
        let csqttWebPort = providerConfiguration["csqttWebPort"] as? Int
        let csqttClientTag = (providerConfiguration["csqttClientTag"] as? String) ?? ""
        let csqttDeviceID = (providerConfiguration["csqttDeviceID"] as? String) ?? ""
        let csqttExtraThreads = max((providerConfiguration["csqttExtraThreads"] as? Int) ?? 0, 0)
        let csqttUseMasking = (providerConfiguration["csqttUseMasking"] as? Bool) ?? true
        let seededTURN = providerConfiguration["seededTURN"] as? [String: String]

        if useSingleProxyWorker && requestedNValue != 1 {
            SharedLogger.warning(
                "Amnezia obfuscation detected; forcing a single proxy connection to preserve handshake packet order",
                source: .tunnel
            )
        }
        SharedLogger.info("Peer: \(peerAddr), Mode: \(transportMode), N: \(nValue), TURN override: \(turnHost.isEmpty ? "auto" : turnHost):\(turnPort.isEmpty ? "auto" : turnPort), UDP: \(useUdp)", source: .tunnel)
        if isWDTT {
            SharedLogger.info(
                "WDTT config: vkLinkLen=\(vkLink.count), passwordSet=\(!wdttPassword.isEmpty), primaryHashLen=\(wdttClientKey.count), extraHashesLen=\(wdttServerKey.count)",
                source: .tunnel
            )
        } else if isCSQTT {
            SharedLogger.info(
                "CSQTT config: vkLinkLen=\(vkLink.count), passwordSet=\(!csqttPassword.isEmpty), webPort=\(csqttWebPort ?? 0), clientTagLen=\(csqttClientTag.count)",
                source: .tunnel
            )
        }

        guard let proxyConfigJSON = makeAntonProxyConfigJSON(
            mode: transportMode,
            vkLink: vkLink,
            peerAddr: peerAddr,
            listenAddr: listenAddr,
            turnHost: turnHost,
            turnPort: turnPort,
            useUdp: useUdp,
            nValue: Int(nValue),
            wrapKeyHex: wrapKeyHex,
            wdttPassword: wdttPassword,
            wdttFingerprint: wdttFingerprint,
            wdttClientIDMode: wdttClientIDMode,
            wdttUseVKCallsPreflight: wdttUseVKCallsPreflight,
            csqttPassword: csqttPassword,
            csqttWebPort: csqttWebPort,
            csqttClientTag: csqttClientTag,
            csqttDeviceID: csqttDeviceID,
            csqttExtraThreads: csqttExtraThreads,
            csqttUseMasking: csqttUseMasking,
            seededTURN: seededTURN
        ) else {
            SharedLogger.error("Failed to encode proxy config", source: .tunnel)
            completionHandler(PacketTunnelProviderError.invalidProtocolConfiguration)
            return
        }

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { return }
            let bootstrapStartedAt = Date()
            NSLog("CSQTT/WDTT: starting bootstrap runtime mode=%@", transportMode)
            SharedLogger.info("Starting VK/TURN bootstrap runtime", source: .tunnel)
            let handle = proxyConfigJSON.withCString {
                VBridgeWGStartVKBootstrap(UnsafeMutablePointer(mutating: $0))
            }
            guard handle >= 0 else {
                SharedLogger.error("VBridgeWGStartVKBootstrap failed: \(handle)", source: .tunnel)
                completionHandler(PacketTunnelProviderError.invalidProtocolConfiguration)
                return
            }
            self.vbridgeTunnelHandle = handle
            NSLog("CSQTT/WDTT: bootstrap handle=%d mode=%@", handle, transportMode)
            SharedLogger.info("VK/TURN bootstrap runtime started; waiting for readiness", source: .tunnel)

            var networkSettings: NEPacketTunnelNetworkSettings
            var effectiveUAPI = wgUAPI
            NSLog("CSQTT/WDTT: waiting bootstrap ready handle=%d timeoutMs=120000", handle)
            let ready = VBridgeWGWaitBootstrapReady(handle, 120000)
            let bootstrapElapsed = Int(Date().timeIntervalSince(bootstrapStartedAt) * 1000)
            guard ready == 1 else {
                VBridgeWGTurnOff(handle)
                self.vbridgeTunnelHandle = -1
                if ready == 0 {
                    SharedLogger.error("VK/TURN bootstrap timed out after \(bootstrapElapsed)ms", source: .tunnel)
                } else {
                    SharedLogger.error("VK/TURN bootstrap failed after \(bootstrapElapsed)ms: \(ready)", source: .tunnel)
                }
                completionHandler(PacketTunnelProviderError.invalidProtocolConfiguration)
                return
            }
            NSLog("CSQTT/WDTT: bootstrap ready handle=%d elapsedMs=%d", handle, bootstrapElapsed)
            SharedLogger.info("VK/TURN bootstrap ready after \(bootstrapElapsed)ms", source: .tunnel)

            let turnServerIP = self.currentTURNServerIP(handle: handle)
            if turnServerIP.isEmpty {
                SharedLogger.warning("Bootstrap ready but TURN server IP is empty", source: .tunnel)
            } else {
                SharedLogger.info("TURN server IP: \(turnServerIP)", source: .tunnel)
            }
            self.activeTunnelRemoteAddress = turnServerIP.isEmpty ? "10.0.0.1" : turnServerIP

            if isWDTT {
                SharedLogger.info("WDTT waiting for WRAP-A GETCONF provision", source: .tunnel)
                let provisionStartedAt = Date()
                guard let provisionJSON = self.waitForWrapAProvision(handle: handle, timeoutMs: 30000),
                      let provision = try? JSONDecoder().decode(WrapAProvision.self, from: Data(provisionJSON.utf8)),
                      !provision.uapi.isEmpty else {
                    VBridgeWGTurnOff(handle)
                    self.vbridgeTunnelHandle = -1
                    let elapsed = Int(Date().timeIntervalSince(provisionStartedAt) * 1000)
                    SharedLogger.error("WDTT provision failed or timed out after \(elapsed)ms", source: .tunnel)
                    completionHandler(PacketTunnelProviderError.invalidProtocolConfiguration)
                    return
                }
                let provisionElapsed = Int(Date().timeIntervalSince(provisionStartedAt) * 1000)
                SharedLogger.info("WDTT provision received after \(provisionElapsed)ms: bytes=\(provisionJSON.utf8.count)", source: .tunnel)
                effectiveUAPI = provision.uapi
                let effectiveMTU = wdttTunnelMTU.flatMap { $0 > 0 ? $0 : nil } ?? provision.mtu ?? 1280
                self.activeProvisionAddress = provision.address
                self.activeProvisionFallbackDNS = provision.dns
                self.activeProvisionMTU = String(effectiveMTU)
                networkSettings = self.createTunnelSettings(
                    address: provision.address,
                    dns: effectiveDNSString(mode: dnsMode, primary: dnsPrimary, secondary: dnsSecondary, fallbackDNS: provision.dns),
                    mtu: String(effectiveMTU),
                    tunnelRemoteAddress: self.activeTunnelRemoteAddress,
                    splitTunnel: splitTunnel
                )
            } else if isCSQTT {
                NSLog("CSQTT: waiting provision handle=%d timeoutMs=30000", handle)
                SharedLogger.info("CSQTT waiting for TUNCONF provision", source: .tunnel)
                let provisionStartedAt = Date()
                guard let provisionJSON = self.waitForCSQTTProvision(handle: handle, timeoutMs: 30000),
                      let provision = try? JSONDecoder().decode(CSQTTProvision.self, from: Data(provisionJSON.utf8)),
                      !provision.address.isEmpty else {
                    VBridgeWGTurnOff(handle)
                    self.vbridgeTunnelHandle = -1
                    let elapsed = Int(Date().timeIntervalSince(provisionStartedAt) * 1000)
                    SharedLogger.error("CSQTT provision failed or timed out after \(elapsed)ms", source: .tunnel)
                    completionHandler(PacketTunnelProviderError.invalidProtocolConfiguration)
                    return
                }
                let provisionElapsed = Int(Date().timeIntervalSince(provisionStartedAt) * 1000)
                NSLog("CSQTT: provision received handle=%d elapsedMs=%d payloadBytes=%d", handle, provisionElapsed, provisionJSON.utf8.count)
                SharedLogger.info("CSQTT provision received after \(provisionElapsed)ms: bytes=\(provisionJSON.utf8.count)", source: .tunnel)
                self.activeProvisionAddress = provision.address
                self.activeProvisionFallbackDNS = provision.dns
                self.activeProvisionMTU = String(provision.mtu > 0 ? provision.mtu : 1280)
                networkSettings = self.createTunnelSettings(
                    address: provision.address,
                    dns: effectiveDNSString(mode: dnsMode, primary: dnsPrimary, secondary: dnsSecondary, fallbackDNS: provision.dns),
                    mtu: String(provision.mtu > 0 ? provision.mtu : 1280),
                    tunnelRemoteAddress: self.activeTunnelRemoteAddress,
                    splitTunnel: splitTunnel
                )
            } else if let tunnelConfiguration = tunnelConfiguration {
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

            DispatchQueue.main.async {
                NSLog("CSQTT/WDTT: applying tunnel network settings handle=%d", handle)
                SharedLogger.info("Applying packet tunnel network settings", source: .tunnel)
                self.setTunnelNetworkSettings(networkSettings) { error in
                    if let error = error {
                        VBridgeWGTurnOff(handle)
                        self.vbridgeTunnelHandle = -1
                        SharedLogger.error("Failed to apply packet tunnel network settings: \(error.localizedDescription)", source: .tunnel)
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

                    let attachResult: Int32
                    if isCSQTT {
                        NSLog("CSQTT: attaching TUN handle=%d tunFd=%d", handle, tunFd)
                        attachResult = VBridgeWGAttachCSQTT(handle, tunFd)
                    } else {
                        attachResult = effectiveUAPI.withCString {
                            VBridgeWGAttachWireGuard(handle, UnsafeMutablePointer(mutating: $0), tunFd)
                        }
                    }
                    guard attachResult == 1 else {
                        VBridgeWGTurnOff(handle)
                        self.vbridgeTunnelHandle = -1
                        if isCSQTT {
                            SharedLogger.error("VBridgeWGAttachCSQTT failed: \(attachResult)", source: .tunnel)
                        } else {
                            SharedLogger.error("VBridgeWGAttachWireGuard failed: \(attachResult)", source: .wireguard)
                        }
                        completionHandler(PacketTunnelProviderError.invalidProtocolConfiguration)
                        return
                    }
                    NSLog("CSQTT/WDTT: attach success handle=%d mode=%@", handle, transportMode)
                    self.lastAppliedNetworkSettings = networkSettings
                    if isCSQTT {
                        SharedLogger.info("Tunnel up with CSQTT runtime", source: .tunnel)
                    } else {
                        SharedLogger.info("Tunnel up with vk-turn-proxy-ios runtime", source: .wireguard)
                        self.startPathMonitoringIfNeeded()
                    }
                    SharedLogger.info("Packet tunnel startup completed; reporting Connected to iOS", source: .tunnel)
                    completionHandler(nil)
                }
            }
        }
    }

    private struct WrapAProvision: Decodable {
        let address: String
        let dns: String
        let mtu: Int?
        let uapi: String
    }

    private struct CSQTTProvision: Decodable {
        let address: String
        let dns: String
        let mtu: Int
        let localPort: Int?
    }

    private func makeAntonProxyConfigJSON(
        mode: String,
        vkLink: String,
        peerAddr: String,
        listenAddr: String,
        turnHost: String,
        turnPort: String,
        useUdp: Bool,
        nValue: Int,
        wrapKeyHex: String,
        wdttPassword: String,
        wdttFingerprint: String,
        wdttClientIDMode: String,
        wdttUseVKCallsPreflight: Bool,
        csqttPassword: String,
        csqttWebPort: Int?,
        csqttClientTag: String,
        csqttDeviceID: String,
        csqttExtraThreads: Int,
        csqttUseMasking: Bool,
        seededTURN: [String: String]?
    ) -> String? {
        let useWDTT = mode == "wdtt"
        let useCSQTT = mode == "csqtt"
        let useSRTPCommunity = mode == "srtpCommunity"
        var payload: [String: Any] = [
            "vk_link": vkLink,
            "peer_addr": peerAddr,
            "listen_addr": listenAddr,
            "turn_server": turnHost,
            "turn_port": turnPort,
            "use_dtls": !useWDTT && !useCSQTT,
            "use_udp": useUdp,
            "use_wrap": useSRTPCommunity,
            "wrap_key_hex": wrapKeyHex,
            "use_srtp": false,
            "use_wrap_a": useWDTT,
            "wrap_a_password": wdttPassword,
            "device_id": resolvedDeviceID(mode: mode, csqttDeviceID: csqttDeviceID),
            "num_conns": max(nValue, 1),
            "cred_pool_cooldown_seconds": 120,
            "browser_fingerprint": wdttFingerprint,
            "client_id_only": wdttClientIDMode,
            "force_legacy_captcha": !wdttUseVKCallsPreflight
        ]
        if useCSQTT {
            payload["use_csqtt"] = true
            payload["csqtt_password"] = csqttPassword
            if let csqttWebPort, csqttWebPort > 0 {
                payload["csqtt_web_port"] = csqttWebPort
            }
            if !csqttClientTag.isEmpty {
                payload["csqtt_client_tag"] = csqttClientTag
            }
            payload["csqtt_extra_threads"] = max(csqttExtraThreads, 0)
            payload["csqtt_use_masking"] = csqttUseMasking
        }
        if let seededTURN,
           let address = seededTURN["address"], !address.isEmpty,
           let username = seededTURN["username"], !username.isEmpty,
           let password = seededTURN["password"], !password.isEmpty {
            payload["seeded_turn"] = [
                "address": address,
                "username": username,
                "password": password
            ]
        }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    private func resolvedDeviceID(mode: String, csqttDeviceID: String) -> String {
        if mode == "csqtt" {
            let trimmed = csqttDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return persistedDeviceID()
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

        // Sideloaded builds commonly lose the App Group entitlement even though
        // the packet-tunnel extension itself is allowed to run.  The extension
        // still owns a persistent preferences container, so use it as the
        // fallback.  Returning a fresh UUID here used to register a new WDTT
        // device on every connection attempt and could eventually exhaust the
        // server's WireGuard address pool, which is reported as NOCONF.
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let value = UUID().uuidString
        defaults.set(value, forKey: key)
        return value
    }

    private func waitForWrapAProvision(handle: Int32, timeoutMs: Int32) -> String? {
        guard let pointer = VBridgeWGWaitWrapAProvision(handle, timeoutMs) else {
            return nil
        }
        defer { free(UnsafeMutableRawPointer(pointer)) }
        let json = String(cString: pointer)
        return json.isEmpty ? nil : json
    }

    private func waitForCSQTTProvision(handle: Int32, timeoutMs: Int32) -> String? {
        guard let pointer = VBridgeWGWaitCSQTTProvision(handle, timeoutMs) else {
            return nil
        }
        defer { free(UnsafeMutableRawPointer(pointer)) }
        let json = String(cString: pointer)
        return json.isEmpty ? nil : json
    }

    private func currentTURNServerIP(handle: Int32) -> String {
        guard let pointer = VBridgeWGGetTURNServerIP(handle) else {
            return ""
        }
        defer { free(UnsafeMutableRawPointer(pointer)) }
        return String(cString: pointer)
    }

    private func createTunnelSettings(
        address: String,
        dns: String,
        mtu: String,
        tunnelRemoteAddress: String,
        splitTunnel: SplitTunnelConfiguration
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
        applySplitTunnelConfiguration(splitTunnel, to: settings)
        return settings
    }

    private var usesProxyLifecycleHooks: Bool {
        vbridgeTunnelHandle >= 0 && activeTransportMode != "csqtt"
    }

    private func startPathMonitoringIfNeeded() {
        guard usesProxyLifecycleHooks else { return }
        guard pathMonitor == nil else { return }

        let monitor = Network.NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] (path: Network.NWPath) in
            self?.handlePathUpdate(path)
        }
        pathMonitor = monitor
        lastObservedPathSummary = nil
        monitor.start(queue: pathMonitorQueue)
        SharedLogger.info("Started NWPathMonitor for tunnel lifecycle recovery", source: .tunnel)
    }

    private func stopPathMonitoring() {
        pathMonitor?.cancel()
        pathMonitor = nil
        lastObservedPathSummary = nil
    }

    private func handlePathUpdate(_ path: Network.NWPath) {
        guard usesProxyLifecycleHooks else { return }

        let summary = pathSummary(path)
        guard summary != lastObservedPathSummary else { return }
        lastObservedPathSummary = summary

        SharedLogger.info("Network path update: \(summary)", source: .tunnel)
        logPathSnapshot(label: summary)

        if path.status != .satisfied {
            SharedLogger.warning("Path became unavailable; marking transport transition", source: .tunnel)
            VBridgeWGPathInTransition(vbridgeTunnelHandle)
            return
        }

        if path.usesInterfaceType(.other) &&
            !path.usesInterfaceType(.wifi) &&
            !path.usesInterfaceType(.cellular) &&
            !path.usesInterfaceType(.wiredEthernet) {
            SharedLogger.debug("Path is temporarily routed via .other; extending transition pause", source: .tunnel)
            VBridgeWGPathInTransition(vbridgeTunnelHandle)
            return
        }

        VBridgeWGPathChanged(vbridgeTunnelHandle)
    }

    private func logPathSnapshot(label: String) {
        guard usesProxyLifecycleHooks else { return }
        label.withCString { cString in
            VBridgeWGLogPathSnapshot(vbridgeTunnelHandle, UnsafeMutablePointer(mutating: cString))
        }
    }

    private func pathSummary(_ path: Network.NWPath) -> String {
        let status: String
        switch path.status {
        case .satisfied:
            status = "satisfied"
        case .requiresConnection:
            status = "requires-connection"
        case .unsatisfied:
            status = "unsatisfied"
        @unknown default:
            status = "unknown"
        }

        var interfaces: [String] = []
        if path.usesInterfaceType(.wifi) { interfaces.append("wifi") }
        if path.usesInterfaceType(.cellular) { interfaces.append("cellular") }
        if path.usesInterfaceType(.wiredEthernet) { interfaces.append("wired") }
        if path.usesInterfaceType(.loopback) { interfaces.append("loopback") }
        if path.usesInterfaceType(.other) { interfaces.append("other") }
        if interfaces.isEmpty { interfaces.append("none") }

        var flags: [String] = []
        if path.isExpensive { flags.append("expensive") }
        if path.isConstrained { flags.append("constrained") }
        if flags.isEmpty { flags.append("standard") }

        return "\(interfaces.joined(separator: "+"))-\(status)-\(flags.joined(separator: "+"))"
    }

    private func applyDNSOverride(
        mode: String,
        primary: String,
        secondary: String,
        to tunnelConfiguration: TunnelConfiguration
    ) {
        let servers = effectiveDNSServers(mode: mode, primary: primary, secondary: secondary, fallbackDNS: "")
        guard !servers.isEmpty else { return }
        tunnelConfiguration.interface.dns = servers.compactMap(DNSServer.init(from:))
    }

    private func effectiveDNSString(
        mode: String,
        primary: String,
        secondary: String,
        fallbackDNS: String
    ) -> String {
        let servers = effectiveDNSServers(mode: mode, primary: primary, secondary: secondary, fallbackDNS: fallbackDNS)
        return servers.isEmpty ? fallbackDNS : servers.joined(separator: ",")
    }

    private func effectiveDNSServers(
        mode: String,
        primary: String,
        secondary: String,
        fallbackDNS: String
    ) -> [String] {
        switch mode {
        case "cloudflare":
            return ["1.1.1.1", "1.0.0.1"]
        case "google":
            return ["8.8.8.8", "8.8.4.4"]
        case "quad9":
            return ["9.9.9.9", "149.112.112.112"]
        case "adguard":
            return ["94.140.14.14", "94.140.15.15"]
        case "adguardFamily":
            return ["94.140.14.15", "94.140.15.16"]
        case "cleanBrowsingFamily":
            return ["185.228.168.168", "185.228.169.168"]
        case "cleanBrowsingSecurity":
            return ["185.228.168.9", "185.228.169.9"]
        case "custom":
            return [primary, secondary]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        default:
            return fallbackDNS
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
    }

    private func applySplitTunnelConfiguration(
        _ splitTunnel: SplitTunnelConfiguration,
        to networkSettings: NEPacketTunnelNetworkSettings
    ) {
        guard splitTunnel.enabled, !splitTunnel.rules.isEmpty else {
            SharedLogger.info("Split tunneling disabled for WDTT network settings", source: .tunnel)
            return
        }

        let compiled = compileSplitTunnelRules(splitTunnel.rules)
        let concreteRanges = rangesResolvedForSplitTunnel(compiled)
        let ipv4Routes = concreteRanges.compactMap(makeIPv4Route)
        let ipv6Routes = concreteRanges.compactMap(makeIPv6Route)
        let runtimeMatchDomains = deduplicatedStrings(
            compiled.exactDomains + compiled.wildcardDomains.map { String($0.dropFirst(2)) }
        )

        if splitTunnel.mode == .direct {
            networkSettings.ipv4Settings?.excludedRoutes = deduplicatedIPv4Routes(
                (networkSettings.ipv4Settings?.excludedRoutes ?? []) + ipv4Routes
            )
            networkSettings.ipv6Settings?.excludedRoutes = deduplicatedIPv6Routes(
                (networkSettings.ipv6Settings?.excludedRoutes ?? []) + ipv6Routes
            )
            // Domain addresses are resolved before the default route is installed. Keep
            // DNS on the physical interface so future resolutions can also bypass VPN.
            networkSettings.dnsSettings?.matchDomains = nil
        } else {
            var includedIPv4 = ipv4Routes
            var includedIPv6 = ipv6Routes
            if let dnsSettings = networkSettings.dnsSettings {
                for server in dnsSettings.servers {
                    if let range = IPAddressRange(from: server) {
                        if let route = makeIPv4Route(range) {
                            includedIPv4.append(route)
                        } else if let route = makeIPv6Route(range) {
                            includedIPv6.append(route)
                        }
                    }
                }
                dnsSettings.matchDomains = runtimeMatchDomains.isEmpty ? nil : runtimeMatchDomains
            }
            networkSettings.ipv4Settings?.includedRoutes = deduplicatedIPv4Routes(includedIPv4)
            networkSettings.ipv6Settings?.includedRoutes = deduplicatedIPv6Routes(includedIPv6)
        }

        SharedLogger.info(
            "WDTT split tunneling applied mode=\(splitTunnel.mode.rawValue) rules=\(splitTunnel.rules.count) ipv4Routes=\(ipv4Routes.count) ipv6Routes=\(ipv6Routes.count) domains=\(runtimeMatchDomains.count)",
            source: .tunnel
        )
    }

    private func makeIPv4Route(_ range: IPAddressRange) -> NEIPv4Route? {
        guard range.address is IPv4Address else { return nil }
        return NEIPv4Route(
            destinationAddress: "\(range.maskedAddress())",
            subnetMask: "\(range.subnetMask())"
        )
    }

    private func makeIPv6Route(_ range: IPAddressRange) -> NEIPv6Route? {
        guard range.address is IPv6Address else { return nil }
        return NEIPv6Route(
            destinationAddress: "\(range.maskedAddress())",
            networkPrefixLength: NSNumber(value: range.networkPrefixLength)
        )
    }

    private func deduplicatedIPv4Routes(_ routes: [NEIPv4Route]) -> [NEIPv4Route] {
        var seen = Set<String>()
        return routes.filter { seen.insert("\($0.destinationAddress)/\($0.destinationSubnetMask)").inserted }
    }

    private func deduplicatedIPv6Routes(_ routes: [NEIPv6Route]) -> [NEIPv6Route] {
        var seen = Set<String>()
        return routes.filter { seen.insert("\($0.destinationAddress)/\($0.destinationNetworkPrefixLength)").inserted }
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
        stopPathMonitoring()
        didPauseProxyForSleep = false
        activeTransportMode = "wg"
        let startedAt = Date()
        let completionLock = NSLock()
        var didComplete = false
        let completeOnce: (String) -> Void = { origin in
            completionLock.lock()
            let shouldComplete = !didComplete
            didComplete = true
            completionLock.unlock()

            guard shouldComplete else { return }
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            SharedLogger.info("stopTunnel completion from \(origin) after \(elapsedMs)ms", source: .tunnel)
            completionHandler()
        }

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 3.0) {
            completeOnce("safety timeout")
        }

        if vbridgeTunnelHandle >= 0 {
            VBridgeWGTurnOff(vbridgeTunnelHandle)
            vbridgeTunnelHandle = -1
            SharedLogger.info("vk-turn-proxy-ios runtime stopped", source: .tunnel)
            clearCaptchaRequest()
            clearCaptchaRecoveryRequest()
            SharedLogger.info("Tunnel stopped", source: .tunnel)
            completeOnce("vk-turn-proxy-ios stop")
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
            completeOnce("adapter stop")

            #if os(macOS)
            // HACK: We have to kill the tunnel process ourselves because of a macOS bug
            exit(0)
            #endif
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard let completionHandler = completionHandler else { return }

        if messageData == Data("vbridge_provider_probe".utf8) {
            let response = "alive handle=\(vbridgeTunnelHandle)"
            completionHandler(Data(response.utf8))
            return
        }

        if messageData == Data(tunnelLogExportMessage.utf8) {
            sharedLogger.log("handleAppMessage: tunnel log export requested")
            guard let logURL = extensionDocumentsLogURL() else {
                sharedLogger.error("handleAppMessage: extension documents directory unavailable")
                completionHandler(nil)
                return
            }
            guard let data = try? Data(contentsOf: logURL) else {
                sharedLogger.error("handleAppMessage: tunnel log file unavailable at \(logURL.path, privacy: .public)")
                completionHandler(nil)
                return
            }
            completionHandler(data)
            return
        }

        if let request = try? JSONDecoder().decode(DNSUpdateRequest.self, from: messageData),
           request.command == "update_dns" {
            applyDNSUpdate(request, completionHandler: completionHandler)
            return
        }

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

    private var lastAppliedNetworkSettings: NEPacketTunnelNetworkSettings?

    private struct DNSUpdateRequest: Decodable {
        let command: String
        let mode: String
        let primary: String
        let secondary: String
    }

    private struct DNSUpdateResponse: Encodable {
        let ok: Bool
        let requiresRestart: Bool
        let message: String
    }

    private func applyDNSUpdate(_ request: DNSUpdateRequest, completionHandler: @escaping (Data?) -> Void) {
        if activeSplitTunnel.enabled && activeSplitTunnel.mode == .tunnel && activeTransportMode != "wdtt" && activeTransportMode != "csqtt" {
            completionHandler(encodeDNSUpdateResponse(.init(
                ok: false,
                requiresRestart: true,
                message: "DNS update requires tunnel restart when tunnel-only split routing is active."
            )))
            return
        }

        if activeTransportMode == "wdtt" || activeTransportMode == "csqtt" {
            let dns = effectiveDNSString(
                mode: request.mode,
                primary: request.primary,
                secondary: request.secondary,
                fallbackDNS: activeProvisionFallbackDNS
            )
            let settings = createTunnelSettings(
                address: activeProvisionAddress,
                dns: dns,
                mtu: activeProvisionMTU,
                tunnelRemoteAddress: activeTunnelRemoteAddress,
                splitTunnel: activeSplitTunnel
            )
            setTunnelNetworkSettings(settings) { error in
                if let error {
                    completionHandler(self.encodeDNSUpdateResponse(.init(
                        ok: false,
                        requiresRestart: true,
                        message: "Failed to apply DNS settings: \(error.localizedDescription)"
                    )))
                    return
                }
                self.lastAppliedNetworkSettings = settings
                SharedLogger.info("Applied live DNS update for \(self.activeTransportMode) tunnel", source: .tunnel)
                completionHandler(self.encodeDNSUpdateResponse(.init(
                    ok: true,
                    requiresRestart: false,
                    message: "DNS updated without reconnect."
                )))
            }
            return
        }

        guard !activeBaseWgQuickConfig.isEmpty,
              let updatedConfiguration = try? TunnelConfiguration(fromWgQuickConfig: activeBaseWgQuickConfig) else {
            completionHandler(encodeDNSUpdateResponse(.init(
                ok: false,
                requiresRestart: true,
                message: "Live DNS update is unavailable for this tunnel state."
            )))
            return
        }

        applyDNSOverride(mode: request.mode, primary: request.primary, secondary: request.secondary, to: updatedConfiguration)
        applySplitTunnelConfiguration(activeSplitTunnel, to: updatedConfiguration)
        adapter.update(tunnelConfiguration: updatedConfiguration) { error in
            if let error {
                completionHandler(self.encodeDNSUpdateResponse(.init(
                    ok: false,
                    requiresRestart: true,
                    message: "Failed to apply DNS settings: \(error.localizedDescription)"
                )))
                return
            }
            SharedLogger.info("Applied live DNS update for WireGuard tunnel", source: .tunnel)
            completionHandler(self.encodeDNSUpdateResponse(.init(
                ok: true,
                requiresRestart: false,
                message: "DNS updated without reconnect."
            )))
        }
    }

    private func encodeDNSUpdateResponse(_ response: DNSUpdateResponse) -> Data? {
        try? JSONEncoder().encode(response)
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        if usesProxyLifecycleHooks {
            SharedLogger.info("Extension sleep callback received; pausing proxy runtime", source: .tunnel)
            VBridgeWGPause(vbridgeTunnelHandle)
            didPauseProxyForSleep = true
        }
        completionHandler()
    }

    override func wake() {
        guard usesProxyLifecycleHooks else { return }

        SharedLogger.info("Extension wake callback received; resuming proxy runtime", source: .tunnel)
        if didPauseProxyForSleep {
            VBridgeWGResume(vbridgeTunnelHandle)
            didPauseProxyForSleep = false
        }
        VBridgeWGWakeHealthCheck(vbridgeTunnelHandle)
        logPathSnapshot(label: "wake")
    }
}
