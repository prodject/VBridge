//
//  Created by nullcstring.
//

import Foundation

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

    var peerAddr: String {
        "\(host):\(serverPort)"
    }

    var vkLink: String {
        "https://vk.com/call/join/\(hashes.first ?? "")"
    }
}

struct DeploySettingsLink: Codable {
    let version: Int
    let nonce: UUID
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

        let payload = String(trimmed.dropFirst(wdttScheme.count))
        let parts = payload.split(separator: ":", maxSplits: 5).map(String.init)
        guard parts.count == 6 else {
            throw ConfigParseError.invalidWDTTLink("Expected host:dtlsPort:wgPort:localPeerPort:password:hash[,hash].")
        }

        let host = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let serverPort = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let configPort = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        let localPort = parts[3].trimmingCharacters(in: .whitespacesAndNewlines)
        let password = parts[4].trimmingCharacters(in: .whitespacesAndNewlines)
        let hashes = parts[5]
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !host.isEmpty else {
            throw ConfigParseError.invalidWDTTLink("Host is empty.")
        }
        for port in [serverPort, configPort, localPort] {
            guard let value = Int(port), (1...65535).contains(value) else {
                throw ConfigParseError.invalidWDTTLink("Invalid port: \(port).")
            }
        }
        guard !password.isEmpty else {
            throw ConfigParseError.invalidWDTTLink("Password is empty.")
        }
        guard !hashes.isEmpty else {
            throw ConfigParseError.invalidWDTTLink("VK hash is empty.")
        }

        return WDTTConfigImport(
            host: host,
            serverPort: serverPort,
            configPort: configPort,
            localPort: localPort,
            password: password,
            hashes: hashes
        )
    }
}
