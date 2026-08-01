import Foundation
import WireGuardKitGo

struct ServerOutboundTarget: Encodable {
    var host: String
    var user: String
    var password: String
    var port: Int
}

struct ServerOutboundRequest {
    var action: String
    var kind: String = ""
    var proxyHost: String = ""
    var proxyPort: Int = 0
    var login: String = ""
    var secret: String = ""
    var localPort: Int = 0
}

private struct ServerOutboundBridgeRequest: Encodable {
    var action: String
    var host: String
    var user: String
    var password: String
    var port: Int
    var kind: String?
    var proxyHost: String?
    var proxyPort: Int?
    var login: String?
    var secret: String?
    var localPort: Int?
}

struct ServerOutboundEnvelope: Decodable {
    var ok: Bool
    var status: String
    var message: String
    var output: String
}

enum ServerOutboundBridge {
    static func run(_ target: ServerOutboundTarget, request: ServerOutboundRequest) async throws -> ServerOutboundEnvelope {
        try await Task.detached(priority: .userInitiated) {
            let payload = ServerOutboundBridgeRequest(
                action: request.action,
                host: target.host,
                user: target.user,
                password: target.password,
                port: target.port,
                kind: request.kind.isEmpty ? nil : request.kind,
                proxyHost: request.proxyHost.isEmpty ? nil : request.proxyHost,
                proxyPort: request.proxyPort == 0 ? nil : request.proxyPort,
                login: request.login.isEmpty ? nil : request.login,
                secret: request.secret.isEmpty ? nil : request.secret,
                localPort: request.localPort == 0 ? nil : request.localPort
            )
            let data = try JSONEncoder().encode(payload)
            guard let json = String(data: data, encoding: .utf8) else {
                throw NSError(domain: "ServerOutboundBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode outbound request."])
            }
            let pointer = json.withCString {
                VBridgeWGServerOutbound(UnsafeMutablePointer(mutating: $0))
            }
            guard let pointer else {
                throw NSError(domain: "ServerOutboundBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "Empty outbound response."])
            }
            defer { VBridgeWGFreeCString(pointer) }
            let responseJSON = String(cString: pointer)
            guard let responseData = responseJSON.data(using: .utf8) else {
                throw NSError(domain: "ServerOutboundBridge", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid outbound response."])
            }
            let envelope = try JSONDecoder().decode(ServerOutboundEnvelope.self, from: responseData)
            if !envelope.ok {
                throw NSError(domain: "ServerOutboundBridge", code: 4, userInfo: [NSLocalizedDescriptionKey: envelope.message])
            }
            return envelope
        }.value
    }
}
