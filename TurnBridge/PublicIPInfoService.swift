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
            let response: IPWhoResponse = try await fetchJSON(url: url)

            if response.success == false {
                SharedLogger.warning("Public IP lookup ipwho.is failed: success=false")
                return nil
            }

            let ipAddress = clean(response.ip)
            let ispName = clean(response.connection?.isp) ?? clean(response.connection?.org)

            SharedLogger.info(
                String(
                    format: "Public IP lookup result source=ipwho.is isp=%@ ip=%@",
                    ispName ?? "unknown",
                    ipAddress ?? "unknown"
                )
            )

            guard ipAddress != nil || ispName != nil else {
                SharedLogger.warning("Public IP lookup ipwho.is returned empty result")
                return nil
            }

            return PublicIPInfo(
                ipAddress: ipAddress,
                ispName: ispName
            )
        } catch {
            SharedLogger.warning("Public IP lookup ipwho.is failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchJSON<T: Decodable>(url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("VBridge/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200..<300).contains(http.statusCode) else {
            SharedLogger.warning("Public IP lookup ipwho.is HTTP \(http.statusCode)")
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(T.self, from: data)
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
              lowered != "--",
              lowered != "undefined",
              lowered != "n/a" else {
            return nil
        }

        return trimmed
    }
}