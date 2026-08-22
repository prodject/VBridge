//
//  Created by nullcstring.
//

import Foundation

enum DeployServerKind: String, Codable, CaseIterable, Identifiable {
    case wdtt
    case csqtt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wdtt:
            return "WDTT"
        case .csqtt:
            return "CSQTT"
        }
    }
}

struct TurnConfigImport: Codable {
    let mode: String?
    let turn: String
    let peer: String
    let listen: String
    let n: Int
    let credsGroupSize: Int?
    let streamsPerCred: Int?
    let wg: String
    let name: String?
    let turnHost: String?
    let turnPort: String?
    let udp: Bool?
    let wrapKeyHex: String?
    let wdttPassword: String?
    let wdttClientKey: String?
    let wdttServerKey: String?
    let wdttFingerprint: String?
    let wdttClientIDMode: String?
    let wdttUseVKCallsPreflight: Bool?
    let wdttTunnelMTU: Int?
    let csqttPassword: String?
    let csqttWebPort: Int?
    let csqttClientTag: String?
    let csqttDeviceID: String?
    let csqttExtraThreads: Int?
    let csqttUseMasking: Bool?
}

struct AmneziaConfigImport {
    let peerAddr: String
    let wgQuickConfig: String
}

struct WDTTConfigImport {
    let host: String
    let serverPort: String
    let configPort: String
    let localPort: String
    let password: String
    let hashes: [String]
    let profileName: String?
    let maxWorkers: Int?

    var peerAddr: String {
        "\(host):\(serverPort)"
    }

    var vkLink: String {
        guard let firstHash = hashes.first, !firstHash.isEmpty else {
            return ""
        }
        return "https://vk.com/call/join/\(firstHash)"
    }
}

struct CSQTTConfigImport {
    let host: String
    let peerPort: Int
    let password: String
    let hashes: [String]
    let profileName: String?
    let webPort: Int?
    let clientTag: String?
    let deviceID: String?
    let localPort: Int
    let extraThreads: Int?
    let useMasking: Bool?

    var peerAddr: String {
        if host.contains(":") && !host.hasPrefix("[") {
            return "[\(host)]:\(peerPort)"
        }
        return "\(host):\(peerPort)"
    }

    var vkLink: String {
        guard let firstHash = hashes.first, !firstHash.isEmpty else {
            return ""
        }
        return "https://vk.com/call/join/\(firstHash)"
    }
}

struct DeploySettingsLink: Codable {
    let version: Int
    let nonce: UUID
    let deployKind: DeployServerKind
    let host: String
    let user: String
    let password: String
    let sshPort: Int
    let dns1: String
    let dns2: String
    let mainPassword: String
    let adminId: String
    let botToken: String
    let manualPorts: Bool
    let dtlsPort: Int
    let wgPort: Int
    let serverArch: String

    private enum CodingKeys: String, CodingKey {
        case version
        case nonce
        case deployKind
        case host
        case user
        case password
        case sshPort
        case dns1
        case dns2
        case mainPassword
        case adminId
        case botToken
        case manualPorts
        case dtlsPort
        case wgPort
        case serverArch
    }

    init(
        version: Int,
        nonce: UUID,
        deployKind: DeployServerKind,
        host: String,
        user: String,
        password: String,
        sshPort: Int,
        dns1: String,
        dns2: String,
        mainPassword: String,
        adminId: String,
        botToken: String,
        manualPorts: Bool,
        dtlsPort: Int,
        wgPort: Int,
        serverArch: String
    ) {
        self.version = version
        self.nonce = nonce
        self.deployKind = deployKind
        self.host = host
        self.user = user
        self.password = password
        self.sshPort = sshPort
        self.dns1 = dns1
        self.dns2 = dns2
        self.mainPassword = mainPassword
        self.adminId = adminId
        self.botToken = botToken
        self.manualPorts = manualPorts
        self.dtlsPort = dtlsPort
        self.wgPort = wgPort
        self.serverArch = serverArch
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        nonce = try container.decode(UUID.self, forKey: .nonce)
        deployKind = try container.decodeIfPresent(DeployServerKind.self, forKey: .deployKind) ?? .wdtt
        host = try container.decode(String.self, forKey: .host)
        user = try container.decode(String.self, forKey: .user)
        password = try container.decode(String.self, forKey: .password)
        sshPort = try container.decode(Int.self, forKey: .sshPort)
        dns1 = try container.decode(String.self, forKey: .dns1)
        dns2 = try container.decode(String.self, forKey: .dns2)
        mainPassword = try container.decode(String.self, forKey: .mainPassword)
        adminId = try container.decode(String.self, forKey: .adminId)
        botToken = try container.decode(String.self, forKey: .botToken)
        manualPorts = try container.decode(Bool.self, forKey: .manualPorts)
        dtlsPort = try container.decode(Int.self, forKey: .dtlsPort)
        wgPort = try container.decode(Int.self, forKey: .wgPort)
        serverArch = try container.decode(String.self, forKey: .serverArch)
    }
}

enum ConfigParseError: LocalizedError {
    case emptyString
    case invalidScheme
    case invalidBase64
    case invalidJSON(String)
    case missingEndpoint
    case invalidAmneziaConfig(String)
    case invalidWDTTLink(String)
    case invalidCSQTTLink(String)
    
    var errorDescription: String? {
        switch self {
        case .emptyString:
            return "The string is empty."
        case .invalidScheme:
            return "Invalid configuration format. Must start with 'vbridge://'"
        case .invalidBase64:
            return "Invalid Base64 encoding."
        case .invalidJSON(let details):
            return "Failed to parse JSON configuration: \(details)"
        case .missingEndpoint:
            return "The Amnezia config is missing a peer Endpoint."
        case .invalidAmneziaConfig(let details):
            return "Failed to parse Amnezia configuration: \(details)"
        case .invalidWDTTLink(let details):
            return "Failed to parse WDTT link: \(details)"
        case .invalidCSQTTLink(let details):
            return "Failed to parse CSQTT link: \(details)"
        }
    }
}

struct ConfigParser {
    static let scheme = "vbridge://"
    static let deploySettingsScheme = "vbridge://server/"
    static let legacySchemes = ["turnbridge://"]
    static let wdttScheme = "wdtt://"
    static let wdttConnectPrefix = "wdtt://connect?"
    static let csqttScheme = "csqtt://"

    static func exportDeploySettings(_ settings: DeploySettingsLink) throws -> String {
        let data = try JSONEncoder().encode(settings)
        let payload = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return deploySettingsScheme + payload
    }

    static func parseDeploySettings(from string: String) throws -> DeploySettingsLink {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(deploySettingsScheme) else {
            throw ConfigParseError.invalidScheme
        }
        var payload = String(trimmed.dropFirst(deploySettingsScheme.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - payload.count % 4) % 4
        payload += String(repeating: "=", count: padding)
        guard let data = Data(base64Encoded: payload) else {
            throw ConfigParseError.invalidBase64
        }
        do {
            let settings = try JSONDecoder().decode(DeploySettingsLink.self, from: data)
            guard settings.version == 1,
                  !settings.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (1...65535).contains(settings.sshPort),
                  (1...65535).contains(settings.dtlsPort),
                  (1...65535).contains(settings.wgPort),
                  ["amd64", "arm64"].contains(settings.serverArch) else {
                throw ConfigParseError.invalidJSON("Unsupported or invalid server settings.")
            }
            return settings
        } catch let error as ConfigParseError {
            throw error
        } catch {
            throw ConfigParseError.invalidJSON(error.localizedDescription)
        }
    }
    
    static func parse(from string: String) throws -> TurnConfigImport {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmed.isEmpty else {
            throw ConfigParseError.emptyString
        }
        
        let matchedScheme = [scheme] + legacySchemes
        guard let prefix = matchedScheme.first(where: { trimmed.hasPrefix($0) }) else {
            throw ConfigParseError.invalidScheme
        }

        let base64String = String(trimmed.dropFirst(prefix.count))
        
        guard let jsonData = Data(base64Encoded: base64String) else {
            throw ConfigParseError.invalidBase64
        }
        
        do {
            let config = try JSONDecoder().decode(TurnConfigImport.self, from: jsonData)
            return config
        } catch {
            throw ConfigParseError.invalidJSON(error.localizedDescription)
        }
    }

    static func parseAmnezia(from string: String) throws -> AmneziaConfigImport {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            throw ConfigParseError.emptyString
        }

        var peerAddr: String?
        var inPeerSection = false
        var rewrittenLines: [String] = []
        rewrittenLines.reserveCapacity(trimmed.count / 16)

        for line in trimmed.components(separatedBy: .newlines) {
            let lineWithoutComment: String
            if let commentRange = line.range(of: "#") {
                lineWithoutComment = String(line[..<commentRange.lowerBound])
            } else {
                lineWithoutComment = line
            }

            let trimmedLine = lineWithoutComment.trimmingCharacters(in: .whitespacesAndNewlines)
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
                    let value = trimmedLine[trimmedLine.index(after: equalsIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty else {
                        throw ConfigParseError.invalidAmneziaConfig("Endpoint value is empty.")
                    }
                    guard peerAddr == nil else {
                        throw ConfigParseError.invalidAmneziaConfig("Multiple peers are not supported.")
                    }
                    peerAddr = value
                    rewrittenLines.append("Endpoint = 127.0.0.1:9000")
                    continue
                }
            }

            rewrittenLines.append(line)
        }

        guard let peerAddr else {
            throw ConfigParseError.missingEndpoint
        }

        return AmneziaConfigImport(
            peerAddr: peerAddr,
            wgQuickConfig: rewrittenLines.joined(separator: "\n")
        )
    }

    static func parseWDTT(from string: String) throws -> WDTTConfigImport {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ConfigParseError.emptyString
        }
        guard trimmed.lowercased().hasPrefix(wdttScheme) else {
            throw ConfigParseError.invalidScheme
        }

        if trimmed.lowercased().hasPrefix(wdttConnectPrefix) {
            return try parseModernWDTT(trimmed)
        }
        return try parseLegacyWDTT(trimmed)
    }

    static func parseCSQTT(from string: String) throws -> CSQTTConfigImport {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ConfigParseError.emptyString
        }
        guard trimmed.lowercased().hasPrefix(csqttScheme) else {
            throw ConfigParseError.invalidScheme
        }

        guard let components = URLComponents(string: trimmed) else {
            throw ConfigParseError.invalidCSQTTLink("Invalid csqtt:// URL.")
        }

        let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if host.lowercased() == "connect" {
            return try parseModernCSQTT(components)
        }
        return try parseLegacyCSQTT(components)
    }

    private static func parseLegacyWDTT(_ value: String) throws -> WDTTConfigImport {
        let payload = String(value.dropFirst(wdttScheme.count))
        let parts = payload.split(separator: ":", maxSplits: 5).map(String.init)
        guard parts.count == 6 else {
            throw ConfigParseError.invalidWDTTLink("Expected host:dtlsPort:wgPort:localPeerPort:password:hash[,hash].")
        }

        return try makeWDTTConfig(
            host: parts[0],
            serverPort: parts[1],
            configPort: parts[2],
            localPort: parts[3],
            password: parts[4],
            hashesValue: parts[5],
            profileName: nil,
            maxWorkers: nil
        )
    }

    private static func parseModernWDTT(_ value: String) throws -> WDTTConfigImport {
        guard let components = URLComponents(string: value) else {
            throw ConfigParseError.invalidWDTTLink("Invalid wdtt://connect URL.")
        }
        let queryItems = components.queryItems ?? []
        let queryMap = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name.lowercased(), $0.value ?? "") })

        if let version = queryMap["v"], !version.isEmpty, version != "1" {
            throw ConfigParseError.invalidWDTTLink("Unsupported wdtt://connect version: \(version).")
        }

        let maxWorkers: Int?
        if let rawWorkers = queryMap["max_workers"]?.trimmingCharacters(in: .whitespacesAndNewlines), !rawWorkers.isEmpty {
            guard let parsedWorkers = Int(rawWorkers),
                  parsedWorkers >= 9,
                  parsedWorkers <= 108,
                  parsedWorkers % 9 == 0 else {
                throw ConfigParseError.invalidWDTTLink("Invalid max_workers value: \(rawWorkers).")
            }
            maxWorkers = parsedWorkers
        } else {
            maxWorkers = nil
        }

        return try makeWDTTConfig(
            host: queryMap["host"] ?? "",
            serverPort: queryMap["dtls"] ?? "",
            configPort: queryMap["wg"] ?? "",
            localPort: queryMap["local"] ?? "",
            password: queryMap["password"] ?? "",
            hashesValue: queryMap["hashes"] ?? "",
            profileName: queryMap["name"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            maxWorkers: maxWorkers
        )
    }

    private static func parseLegacyCSQTT(_ components: URLComponents) throws -> CSQTTConfigImport {
        let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let password = components.user?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let peerPort = components.port ?? -1

        guard !host.isEmpty else {
            throw ConfigParseError.invalidCSQTTLink("Host is empty.")
        }
        guard (1...65535).contains(peerPort) else {
            throw ConfigParseError.invalidCSQTTLink("Invalid peer port: \(peerPort).")
        }
        guard !password.isEmpty else {
            throw ConfigParseError.invalidCSQTTLink("Password is empty.")
        }

        return CSQTTConfigImport(
            host: host,
            peerPort: peerPort,
            password: password,
            hashes: [],
            profileName: nil,
            webPort: nil,
            clientTag: nil,
            deviceID: nil,
            localPort: 9000,
            extraThreads: nil,
            useMasking: nil
        )
    }

    private static func parseModernCSQTT(_ components: URLComponents) throws -> CSQTTConfigImport {
        let queryItems = components.queryItems ?? []
        let queryMap = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name.lowercased(), $0.value ?? "") })

        guard queryMap["v"]?.trimmingCharacters(in: .whitespacesAndNewlines) == "2" else {
            throw ConfigParseError.invalidCSQTTLink("Unsupported csqtt://connect version.")
        }

        let host = queryMap["host"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let password = queryMap["password"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !host.isEmpty else {
            throw ConfigParseError.invalidCSQTTLink("Host is empty.")
        }
        guard !password.isEmpty else {
            throw ConfigParseError.invalidCSQTTLink("Password is empty.")
        }
        guard !host.contains(where: \.isWhitespace), !password.contains(where: \.isWhitespace) else {
            throw ConfigParseError.invalidCSQTTLink("Host and password must not contain whitespace.")
        }
        guard let peerPortString = queryMap["peer"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let peerPort = Int(peerPortString),
              (1...65535).contains(peerPort) else {
            throw ConfigParseError.invalidCSQTTLink("Invalid peer port.")
        }

        let webPort: Int?
        if let rawWebPort = queryMap["web"]?.trimmingCharacters(in: .whitespacesAndNewlines), !rawWebPort.isEmpty {
            guard let parsed = Int(rawWebPort), (1...65535).contains(parsed) else {
                throw ConfigParseError.invalidCSQTTLink("Invalid web port.")
            }
            webPort = parsed
        } else {
            webPort = nil
        }

        let localPort: Int
        if let rawLocalPort = queryMap["local"]?.trimmingCharacters(in: .whitespacesAndNewlines), !rawLocalPort.isEmpty {
            guard let parsed = Int(rawLocalPort), (1...65535).contains(parsed) else {
                throw ConfigParseError.invalidCSQTTLink("Invalid local port.")
            }
            localPort = parsed
        } else {
            localPort = 9000
        }

        let extraThreads: Int?
        if let rawExtraThreads = queryMap["extra_threads"]?.trimmingCharacters(in: .whitespacesAndNewlines), !rawExtraThreads.isEmpty {
            guard let parsed = Int(rawExtraThreads), parsed >= 0, parsed <= 64 else {
                throw ConfigParseError.invalidCSQTTLink("Invalid extra_threads value.")
            }
            extraThreads = parsed
        } else {
            extraThreads = nil
        }

        let useMasking: Bool?
        if let rawMask = queryMap["mask"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !rawMask.isEmpty {
            switch rawMask {
            case "1", "true", "yes", "on":
                useMasking = true
            case "0", "false", "no", "off":
                useMasking = false
            default:
                throw ConfigParseError.invalidCSQTTLink("Invalid mask value.")
            }
        } else {
            useMasking = nil
        }

        return CSQTTConfigImport(
            host: host,
            peerPort: peerPort,
            password: password,
            hashes: try parseCSQTTHashes(queryMap["hashes"]),
            profileName: queryMap["name"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            webPort: webPort,
            clientTag: queryMap["tag"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            deviceID: queryMap["device_id"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            localPort: localPort,
            extraThreads: extraThreads,
            useMasking: useMasking
        )
    }

    private static func makeWDTTConfig(
        host: String,
        serverPort: String,
        configPort: String,
        localPort: String,
        password: String,
        hashesValue: String,
        profileName: String?,
        maxWorkers: Int?
    ) throws -> WDTTConfigImport {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedServerPort = serverPort.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedConfigPort = configPort.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLocalPort = localPort.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        let hashes = hashesValue
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !trimmedHost.isEmpty else {
            throw ConfigParseError.invalidWDTTLink("Host is empty.")
        }
        for port in [trimmedServerPort, trimmedConfigPort, trimmedLocalPort] {
            guard let value = Int(port), (1...65535).contains(value) else {
                throw ConfigParseError.invalidWDTTLink("Invalid port: \(port).")
            }
        }
        guard !trimmedPassword.isEmpty else {
            throw ConfigParseError.invalidWDTTLink("Password is empty.")
        }
        return WDTTConfigImport(
            host: trimmedHost,
            serverPort: trimmedServerPort,
            configPort: trimmedConfigPort,
            localPort: trimmedLocalPort,
            password: trimmedPassword,
            hashes: hashes,
            profileName: profileName?.isEmpty == false ? profileName : nil,
            maxWorkers: maxWorkers
        )
    }

    private static func parseCSQTTHashes(_ rawValue: String?) throws -> [String] {
        guard let rawValue else { return [] }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ConfigParseError.invalidCSQTTLink("hashes is present but empty.")
        }

        let hashes = trimmed
            .split(separator: "+", omittingEmptySubsequences: false)
            .map { stripVKJoinPrefix(String($0)).trimmingCharacters(in: .whitespacesAndNewlines) }

        guard (1...6).contains(hashes.count),
              !hashes.contains(where: { $0.isEmpty || $0.contains(where: \.isWhitespace) || $0.count < 16 }) else {
            throw ConfigParseError.invalidCSQTTLink("Invalid hashes list.")
        }
        guard Set(hashes).count == hashes.count else {
            throw ConfigParseError.invalidCSQTTLink("Duplicate hashes are not allowed.")
        }
        return hashes
    }

    private static func stripVKJoinPrefix(_ input: String) -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = value.lowercased()
        let prefixes = [
            "https://vk.com/call/join/",
            "http://vk.com/call/join/",
            "https://m.vk.com/call/join/",
            "http://m.vk.com/call/join/",
            "m.vk.com/call/join/",
            "vk.com/call/join/",
            "https://vk.ru/call/join/",
            "http://vk.ru/call/join/",
            "https://m.vk.ru/call/join/",
            "http://m.vk.ru/call/join/",
            "m.vk.ru/call/join/",
            "vk.ru/call/join/"
        ]

        for prefix in prefixes where lowered.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
            break
        }

        if let questionMark = value.firstIndex(of: "?") {
            value = String(value[..<questionMark])
        }
        if let hashIndex = value.firstIndex(of: "#") {
            value = String(value[..<hashIndex])
        }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
