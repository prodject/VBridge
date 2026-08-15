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
        }
    }
}

struct ConfigParser {
    static let scheme = "vbridge://"
    static let deploySettingsScheme = "vbridge://server/"
    static let legacySchemes = ["turnbridge://"]
    static let wdttScheme = "wdtt://"
    static let wdttConnectPrefix = "wdtt://connect?"

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
}
