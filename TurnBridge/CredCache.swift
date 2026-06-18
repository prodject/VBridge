import Foundation

private struct CredCacheEntry: Codable {
    let slot: Int
    let address: String
    let username: String
    let password: String
    let last_used_at: Int64?
}

private struct CredCacheFile: Codable {
    let version: Int
    let saved_at: Int64
    let creds: [CredCacheEntry]
}

enum CredCache {
    private static let supportedVersion = 2
    private static let expiryGuard: TimeInterval = 30 * 60
    private static let saturationCooldown: TimeInterval = 600

    private static var cacheURL: URL? {
        guard let groupID = SharedLogger.appGroupID else { return nil }
        return FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("creds-pool.json")
    }

    static func loadValidCred() -> SeededTURNCredentials? {
        guard let url = cacheURL,
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(CredCacheFile.self, from: data),
              file.version == supportedVersion else {
            return nil
        }

        let now = Date().timeIntervalSince1970
        var skipReasons: [String] = []

        for entry in file.creds {
            guard let colonIndex = entry.username.firstIndex(of: ":"),
                  let expiry = Double(entry.username[..<colonIndex]) else {
                skipReasons.append("slot \(entry.slot) malformed username")
                continue
            }

            if expiry - now <= expiryGuard {
                skipReasons.append("slot \(entry.slot) expiring in \(Int(expiry - now))s")
                continue
            }

            if let lastUsed = entry.last_used_at, lastUsed > 0 {
                let sinceUse = now - TimeInterval(lastUsed)
                if sinceUse >= 0 && sinceUse < saturationCooldown {
                    skipReasons.append("slot \(entry.slot) last used \(Int(sinceUse))s ago")
                    continue
                }
            }

            SharedLogger.info("CredCache: using slot \(entry.slot), addr=\(entry.address), expires in \(Int(expiry - now))s")
            return SeededTURNCredentials(
                address: entry.address,
                username: entry.username,
                password: entry.password
            )
        }

        if !skipReasons.isEmpty {
            SharedLogger.debug("CredCache: no usable cached cred: \(skipReasons.joined(separator: ", "))")
        }
        return nil
    }
}
