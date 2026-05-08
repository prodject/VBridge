import Foundation

struct PublicIPInfo {
    let ipAddress: String?
    let ispName: String?
}

final class PublicIPInfoService {
    private struct IPWhoResponse: Decodable {
        let success: Bool?
        let ip: String?
        let connection: Connection?

        struct Connection: Decodable {
            let isp: String?
            let org: String?
        }
    }

    func fetch() async -> PublicIPInfo? {
        guard let url = URL(string: "https://ipwho.is/") else {
            return nil
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                SharedLogger.warning("Public IP lookup failed: non-HTTP response")
                return nil
            }

            guard (200..<300).contains(http.statusCode) else {
                SharedLogger.warning("Public IP lookup failed: HTTP \(http.statusCode)")
                return nil
            }

            let decoded = try JSONDecoder().decode(IPWhoResponse.self, from: data)

            if decoded.success == false {
                SharedLogger.warning("Public IP lookup failed: API returned success=false")
                return nil
            }

            let ipAddress = clean(decoded.ip)
            let ispName = clean(decoded.connection?.isp) ?? clean(decoded.connection?.org)

            SharedLogger.info(
                String(
                    format: "Public IP lookup result: isp=%@ ip=%@",
                    ispName ?? "unknown",
                    ipAddress ?? "unknown"
                )
            )

            return PublicIPInfo(
                ipAddress: ipAddress,
                ispName: ispName
            )
        } catch {
            SharedLogger.warning("Public IP lookup failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func clean(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return nil
        }

        let lowered = trimmed.lowercased()

        guard lowered != "unknown",
              lowered != "nil",
              lowered != "null",
              lowered != "--" else {
            return nil
        }

        return trimmed
    }
}