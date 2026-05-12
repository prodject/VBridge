//
//  Created by nullcstring.
//

import Foundation

struct TurnConfigImport: Codable {
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
}

struct AmneziaConfigImport {
    let peerAddr: String
    let wgQuickConfig: String
}

enum ConfigParseError: LocalizedError {
    case emptyString
    case invalidScheme
    case invalidBase64
    case invalidJSON(String)
    case missingEndpoint
    case invalidAmneziaConfig(String)
    
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
        }
    }
}

struct ConfigParser {
    static let scheme = "vbridge://"
    static let legacySchemes = ["turnbridge://"]
    
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
}
