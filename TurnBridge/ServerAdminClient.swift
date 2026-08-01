import Foundation
import WireGuardKitGo

struct ServerAdminTarget: Encodable {
    var host: String
    var user: String
    var password: String
    var port: Int
    var mainPassword: String
}

struct ServerAdminClientInfo: Decodable, Identifiable {
    var password: String
    var label: String?
    var vkHash: String?
    var ports: String?
    var status: String
    var expiresAt: Int64?
    var downBytes: Int64?
    var upBytes: Int64?
    var deviceId: String?

    var id: String { password }
    var title: String { label?.isEmpty == false ? label! : password }
    var isActive: Bool { status == "active" }
}

struct ServerAdminStatePayload: Decodable {
    var passwords: [ServerAdminClientInfo]?
}

struct ServerAdminEnvelope: Decodable {
    var ok: Bool
    var status: String
    var message: String
    var output: String?
    var state: ServerAdminStatePayload?
}

struct ServerAdminCreateRequest {
    var label: String
    var vkHash: String
    var ports: String
    var days: Int
    var clientPassword: String
}

struct ServerAdminUpdateRequest {
    var clientPassword: String
    var label: String
    var vkHash: String
    var ports: String
    var days: Int?
    var expiresAt: Int64?
    var newPassword: String
}

enum ServerAdminAction: String {
    case list
    case create
    case delete
    case unbind
    case activate
    case deactivate
    case setLabel = "set-label"
    case setHash = "set-hash"
    case setPorts = "set-ports"
    case setPassword = "set-password"
    case setExpiry = "set-expiry"
    case updateClient = "update-client"
    case cleanupExpired = "cleanup-expired"
    case cleanupOrphans = "cleanup-orphans"
}

private struct ServerAdminBridgeRequest: Encodable {
    var action: String
    var host: String
    var user: String
    var password: String
    var port: Int
    var mainPassword: String
    var clientPassword: String?
    var label: String?
    var vkHash: String?
    var ports: String?
    var days: Int?
    var expiresAt: Int64?
    var newPassword: String?
}

enum ServerAdminBridge {
    static func list(_ target: ServerAdminTarget) async throws -> [ServerAdminClientInfo] {
        let response = try await call(ServerAdminBridgeRequest(
            action: ServerAdminAction.list.rawValue,
            host: target.host,
            user: target.user,
            password: target.password,
            port: target.port,
            mainPassword: target.mainPassword
        ))
        return response.state?.passwords ?? []
    }

    static func create(_ target: ServerAdminTarget, request: ServerAdminCreateRequest) async throws -> ServerAdminEnvelope {
        try await call(ServerAdminBridgeRequest(
            action: ServerAdminAction.create.rawValue,
            host: target.host,
            user: target.user,
            password: target.password,
            port: target.port,
            mainPassword: target.mainPassword,
            clientPassword: request.clientPassword.isEmpty ? nil : request.clientPassword,
            label: request.label.isEmpty ? nil : request.label,
            vkHash: request.vkHash.isEmpty ? nil : request.vkHash,
            ports: request.ports.isEmpty ? nil : request.ports,
            days: request.days
        ))
    }

    static func update(_ target: ServerAdminTarget, request: ServerAdminUpdateRequest) async throws -> ServerAdminEnvelope {
        try await call(ServerAdminBridgeRequest(
            action: ServerAdminAction.updateClient.rawValue,
            host: target.host,
            user: target.user,
            password: target.password,
            port: target.port,
            mainPassword: target.mainPassword,
            clientPassword: request.clientPassword,
            label: request.label.isEmpty ? nil : request.label,
            vkHash: request.vkHash.isEmpty ? nil : request.vkHash,
            ports: request.ports.isEmpty ? nil : request.ports
        ))
    }

    static func setPassword(_ target: ServerAdminTarget, clientPassword: String, newPassword: String) async throws -> ServerAdminEnvelope {
        try await call(ServerAdminBridgeRequest(
            action: ServerAdminAction.setPassword.rawValue,
            host: target.host,
            user: target.user,
            password: target.password,
            port: target.port,
            mainPassword: target.mainPassword,
            clientPassword: clientPassword,
            newPassword: newPassword
        ))
    }

    static func setExpiry(_ target: ServerAdminTarget, clientPassword: String, days: Int?, expiresAt: Int64?) async throws -> ServerAdminEnvelope {
        try await call(ServerAdminBridgeRequest(
            action: ServerAdminAction.setExpiry.rawValue,
            host: target.host,
            user: target.user,
            password: target.password,
            port: target.port,
            mainPassword: target.mainPassword,
            clientPassword: clientPassword,
            days: days,
            expiresAt: expiresAt
        ))
    }

    static func run(_ action: ServerAdminAction, target: ServerAdminTarget, clientPassword: String) async throws -> ServerAdminEnvelope {
        try await call(ServerAdminBridgeRequest(
            action: action.rawValue,
            host: target.host,
            user: target.user,
            password: target.password,
            port: target.port,
            mainPassword: target.mainPassword,
            clientPassword: clientPassword
        ))
    }

    static func run(_ action: ServerAdminAction, target: ServerAdminTarget) async throws -> ServerAdminEnvelope {
        try await call(ServerAdminBridgeRequest(
            action: action.rawValue,
            host: target.host,
            user: target.user,
            password: target.password,
            port: target.port,
            mainPassword: target.mainPassword
        ))
    }

    private static func call(_ request: ServerAdminBridgeRequest) async throws -> ServerAdminEnvelope {
        try await Task.detached(priority: .userInitiated) {
            let data = try JSONEncoder().encode(request)
            guard let json = String(data: data, encoding: .utf8) else {
                throw NSError(domain: "ServerAdminBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode server admin request."])
            }
            let pointer = json.withCString {
                VBridgeWGServerAdmin(UnsafeMutablePointer(mutating: $0))
            }
            guard let pointer else {
                throw NSError(domain: "ServerAdminBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "Server admin bridge returned an empty response."])
            }
            defer { VBridgeWGFreeCString(pointer) }
            let responseJSON = String(cString: pointer)
            guard let responseData = responseJSON.data(using: .utf8) else {
                throw NSError(domain: "ServerAdminBridge", code: 3, userInfo: [NSLocalizedDescriptionKey: "Server admin bridge returned invalid UTF-8."])
            }
            let envelope = try JSONDecoder().decode(ServerAdminEnvelope.self, from: responseData)
            if !envelope.ok {
                throw NSError(domain: "ServerAdminBridge", code: 4, userInfo: [NSLocalizedDescriptionKey: envelope.message])
            }
            return envelope
        }.value
    }
}
