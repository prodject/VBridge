import Foundation
import WireGuardKitGo
import UIKit

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

struct ServerAdminClientTransferPayload: Codable {
    var format: String
    var version: Int
    var createdAt: Int64
    var password: String
    var label: String?
    var vkHash: String?
    var expiresAt: Int64
    var deactivated: Bool
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

extension ServerAdminClientInfo {
    private enum CodingKeys: String, CodingKey {
        case password
        case label
        case vkHash = "vk_hash"
        case ports
        case status
        case expiresAt = "expires_at"
        case downBytes = "down_bytes"
        case upBytes = "up_bytes"
        case deviceId = "device_id"
    }
}

extension ServerAdminClientTransferPayload {
    private enum CodingKeys: String, CodingKey {
        case format
        case version
        case createdAt = "created_at"
        case password
        case label
        case vkHash = "vk_hash"
        case expiresAt = "expires_at"
        case deactivated
    }
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

    static func exportClient(_ client: ServerAdminClientInfo) throws -> String {
        let payload = ServerAdminClientTransferPayload(
            format: "wdtt-plus-client",
            version: 1,
            createdAt: Int64(Date().timeIntervalSince1970 * 1000),
            password: client.password,
            label: client.label,
            vkHash: client.vkHash,
            expiresAt: client.expiresAt ?? 0,
            deactivated: !client.isActive
        )
        let data = try JSONEncoder().encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "ServerAdminBridge", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to encode client transfer JSON."])
        }
        return text
    }

    static func importClient(_ target: ServerAdminTarget, transferText: String, defaultPorts: String = "56000,56001,9000") async throws -> ServerAdminEnvelope {
        let data = Data(transferText.utf8)
        let payload = try JSONDecoder().decode(ServerAdminClientTransferPayload.self, from: data)
        guard payload.format == "wdtt-plus-client", payload.version == 1 else {
            throw NSError(domain: "ServerAdminBridge", code: 6, userInfo: [NSLocalizedDescriptionKey: "Unsupported client transfer format."])
        }
        let now = Int64(Date().timeIntervalSince1970)
        if payload.expiresAt > 0, payload.expiresAt <= now {
            throw NSError(domain: "ServerAdminBridge", code: 7, userInfo: [NSLocalizedDescriptionKey: "The transferred client has already expired."])
        }
        let response = try await create(target, request: ServerAdminCreateRequest(
            label: payload.label ?? "",
            vkHash: payload.vkHash ?? "",
            ports: defaultPorts,
            days: 0,
            clientPassword: payload.password
        ))
        if payload.expiresAt > 0 {
            _ = try await setExpiry(target, clientPassword: payload.password, days: nil, expiresAt: payload.expiresAt)
        }
        if payload.deactivated {
            _ = try await run(.deactivate, target: target, clientPassword: payload.password)
        }
        return response
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
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let envelope = try decoder.decode(ServerAdminEnvelope.self, from: responseData)
            if !envelope.ok {
                throw NSError(domain: "ServerAdminBridge", code: 4, userInfo: [NSLocalizedDescriptionKey: localizedServerAdminMessage(envelope.message)])
            }
            return envelope
        }.value
    }

    private static func localizedServerAdminMessage(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("порт #"), trimmed.contains("должен быть числом 1..65535") {
            if let number = trimmed.split(separator: "#").dropFirst().first?.split(separator: " ").first {
                return "Port #\(number) must be a number from 1 to 65535."
            }
            return "Every port must be a number from 1 to 65535."
        }
        switch trimmed {
        case "пароль не найден":
            return "Client password not found."
        case "главный пароль администратора не совпадает":
            return "Main admin password does not match."
        case "срок действия клиента истёк":
            return "The client access has already expired."
        case "укажите только один из параметров: days или expires-at":
            return "Specify only one expiry mode: days or expires-at."
        case "новый срок действия уже истёк":
            return "The new expiry time is already in the past."
        case "укажите --password":
            return "Client password is required."
        case "клиент с таким паролем уже существует":
            return "A client with this password already exists."
        case "пароль клиента не должен совпадать с главным паролем":
            return "Client password must not match the main password."
        case "не удалось создать уникальный пароль":
            return "Failed to generate a unique client password."
        default:
            return trimmed
        }
    }
}
