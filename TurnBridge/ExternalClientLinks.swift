import Foundation

/// ConnectionLink schema v1 and colon-separated WDTT links supported by
/// anton48/vk-turn-proxy-ios (BackupManager.swift and quick_link.py).
enum ExternalClientLinks {
    enum LinkError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let message): return message }
        }
    }

    static func callLinks(_ value: String) throws -> [String] {
        try value.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
            .filter { !$0.isEmpty }
            .map { token in
                let hash: String
                if let url = URL(string: token), let scheme = url.scheme {
                    guard scheme.lowercased() == "https",
                          ["vk.com", "vk.ru", "vk.me", "www.vk.com", "www.vk.ru"].contains(url.host?.lowercased() ?? ""),
                          url.path.contains("/join/"), !url.lastPathComponent.isEmpty else {
                        throw LinkError.invalid("Use a VK call join URL or a bare call hash.")
                    }
                    hash = url.lastPathComponent
                } else {
                    hash = token
                }
                let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-="))
                guard !hash.isEmpty, hash.rangeOfCharacter(from: allowed.inverted) == nil else {
                    throw LinkError.invalid("Invalid VK call hash.")
                }
                return "https://vk.ru/call/join/\(hash)"
            }
    }

    static func wdtt(host: String, ports: String, password: String, hashes: String, name: String, legacy: Bool) throws -> String {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = ports.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !host.isEmpty, !password.isEmpty, parts.count == 3,
              parts.allSatisfy({ Int($0).map { (1...65535).contains($0) } ?? false }) else {
            throw LinkError.invalid("The client needs a server address, password and three valid ports.")
        }
        let calls = try callLinks(hashes)
        if legacy {
            guard !calls.isEmpty else {
                throw LinkError.invalid("Classic WDTT links require a VK call URL or hash. Set it using Edit, or choose VK TURN Proxy to keep the receiving app's existing calls.")
            }
            guard !host.contains(":"), !password.contains(":"),
                  password.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
                throw LinkError.invalid("Classic WDTT links cannot represent IPv6 addresses or passwords containing colons or whitespace. Choose VK TURN Proxy instead.")
            }
            let tokens = calls.compactMap { URL(string: $0)?.lastPathComponent }
            guard tokens.count == calls.count, tokens.allSatisfy({ !$0.isEmpty }) else {
                throw LinkError.invalid("Invalid VK call URL or hash.")
            }
            return "wdtt://\(host):\(parts.joined(separator: ":")):\(password):\(tokens.joined(separator: ","))"
        }
        var settings = transportSettings(peer: endpoint(host, port: parts[0]), calls: calls, name: name)
        settings["useSrtp"] = false
        settings["useWrapA"] = true
        settings["wrapAPassword"] = password
        return try encode(settings)
    }

    static func srtp(host: String, port: Int, config: String, calls: String, name: String) throws -> String {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (1...65535).contains(port) else {
            throw LinkError.invalid("Invalid SRTP server address or port.")
        }
        let links = try callLinks(calls)
        var section = ""
        var interface: [String: String] = [:]
        var peer: [String: String] = [:]
        var peerCount = 0
        for raw in config.components(separatedBy: .newlines) {
            let line = String(raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") {
                section = line.lowercased()
                if section == "[peer]" { peerCount += 1 }
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if section == "[interface]" { interface[key] = value }
            if section == "[peer]" { peer[key] = value }
        }
        guard peerCount == 1, let privateKey = interface["privatekey"],
              Data(base64Encoded: privateKey)?.count == 32,
              let publicKey = peer["publickey"], Data(base64Encoded: publicKey)?.count == 32,
              let address = interface["address"], !address.isEmpty else {
            throw LinkError.invalid("The SRTP client needs a WireGuard address, valid keys and exactly one peer.")
        }
        var settings = transportSettings(peer: endpoint(host, port: String(port)), calls: links, name: name)
        settings["useSrtp"] = true
        settings["useWrapA"] = false
        settings["privateKey"] = privateKey
        settings["peerPublicKey"] = publicKey
        settings["tunnelAddress"] = address
        settings["allowedIPs"] = peer["allowedips"] ?? "0.0.0.0/0, ::/0"
        settings["dnsServers"] = interface["dns"] ?? "1.1.1.1"
        let psk = peer["presharedkey"] ?? ""
        guard psk.isEmpty || Data(base64Encoded: psk)?.count == 32 else {
            throw LinkError.invalid("Invalid WireGuard preshared key.")
        }
        // Empty PSK explicitly clears any key retained by the receiving app.
        settings["presharedKey"] = psk
        return try encode(settings)
    }

    private static func endpoint(_ host: String, port: String) -> String {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return host.contains(":") && !host.hasPrefix("[") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    private static func transportSettings(peer: String, calls: [String], name: String) -> [String: Any] {
        ["peerAddress": peer, "vkLink": calls.joined(separator: "\n"), "serverName": name,
         "useDTLS": true, "useUDP": false, "useWrap": false, "useWrapS": false,
         "useCsqtt": false, "numConnections": 30]
    }

    private static func encode(_ settings: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "type": "connection", "settings": settings], options: [.sortedKeys])
        let base64 = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "vkturnproxy://import?data=\(base64)"
    }
}
