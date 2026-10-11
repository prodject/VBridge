import Foundation
import WireGuardKitGo
import UIKit

enum ServerManagementTarget: Sendable {
    case wdtt(ServerAdminTarget)
    case csqtt(CSQTTAdminTarget)
}

struct ServerAdminTarget: Encodable, Sendable {
    var host: String
    var user: String
    var password: String
    var port: Int
    var mainPassword: String
}

struct CSQTTAdminTarget: Encodable, Sendable {
    var host: String
    var user: String
    var password: String
    var port: Int
    var webPort: Int
    var webUser: String
    var webPassword: String
}

struct SRTPAdminTarget: Encodable, Sendable {
    var host: String
    var user: String
    var password: String
    var port: Int
    var dtlsPort: Int
}

struct SRTPAdminClientInfo: Codable, Identifiable, Sendable {
    var id: String
    var label: String
    var address: String
    var publicKey: String
    var createdAt: Int64
    var config: String

    private enum CodingKeys: String, CodingKey {
        case id, label, address, config
        case publicKey = "public_key"
        case createdAt = "created_at"
    }
}

private struct SRTPAdminRequest: Encodable, Sendable {
    var action: String
    var host: String
    var user: String
    var password: String
    var port: Int
    var label: String?
    var clientId: String?
}

private struct SRTPAdminResponse: Decodable, Sendable {
    var ok: Bool
    var message: String
    var clients: [SRTPAdminClientInfo]?
}

enum SRTPAdminBridge {
    static func list(_ target: SRTPAdminTarget) async throws -> [SRTPAdminClientInfo] {
        try await call(action: "list", target: target).clients ?? []
    }

    static func create(_ target: SRTPAdminTarget, label: String) async throws -> [SRTPAdminClientInfo] {
        try await call(action: "create", target: target, label: label).clients ?? []
    }

    static func delete(_ target: SRTPAdminTarget, id: String) async throws -> [SRTPAdminClientInfo] {
        try await call(action: "delete", target: target, clientId: id).clients ?? []
    }

    static func profileLink(_ target: SRTPAdminTarget, client: SRTPAdminClientInfo, turnURL: String) throws -> String {
        let peer = target.host.contains(":") && !target.host.hasPrefix("[")
            ? "[\(target.host)]:\(target.dtlsPort)"
            : "\(target.host):\(target.dtlsPort)"
        let payload: [String: Any] = [
            "mode": "srtp",
            "turn": turnURL.trimmingCharacters(in: .whitespacesAndNewlines),
            "peer": peer,
            "listen": "127.0.0.1:9000",
            "n": 30,
            "wg": client.config,
            "name": client.label.isEmpty ? "SRTP \(client.address)" : client.label,
            "udp": false
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return ConfigParser.scheme + data.base64EncodedString()
    }

    private static func call(action: String, target: SRTPAdminTarget, label: String? = nil, clientId: String? = nil) async throws -> SRTPAdminResponse {
        try await Task.detached(priority: .userInitiated) {
            let request = SRTPAdminRequest(action: action, host: target.host, user: target.user, password: target.password, port: target.port, label: label, clientId: clientId)
            let data = try JSONEncoder().encode(request)
            guard let json = String(data: data, encoding: .utf8) else {
                throw NSError(domain: "SRTPAdminBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode SRTP admin request."])
            }
            let pointer = json.withCString { VBridgeWGSRTPAdmin(UnsafeMutablePointer(mutating: $0)) }
            guard let pointer else {
                throw NSError(domain: "SRTPAdminBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "SRTP admin bridge returned an empty response."])
            }
            defer { VBridgeWGFreeCString(pointer) }
            let response = try JSONDecoder().decode(SRTPAdminResponse.self, from: Data(String(cString: pointer).utf8))
            guard response.ok else {
                throw NSError(domain: "SRTPAdminBridge", code: 3, userInfo: [NSLocalizedDescriptionKey: response.message])
            }
            return response
        }.value
    }
}

struct ServerAdminClientInfo: Codable, Identifiable, Sendable {
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

struct ServerAdminStatePayload: Decodable, Sendable {
    var passwords: [ServerAdminClientInfo]?
    var backupStatus: ServerBackupStatus?
    var backup: ServerBackupSummary?
    var backupDocument: ServerBackupDocument?

    private enum CodingKeys: String, CodingKey {
        case passwords
        case backupStatus = "backup_status"
        case backup
        case backupDocument = "backup_document"
    }
}

struct ServerBackupPolicy: Codable, Sendable {
    var enabled: Bool
    var intervalHours: Int
    var retentionCount: Int

    private enum CodingKeys: String, CodingKey {
        case enabled
        case intervalHours = "interval_hours"
        case retentionCount = "retention_count"
    }
}

struct ServerBackupRuntimeState: Codable, Sendable {
    var lastAttemptAt: Int64?
    var lastSuccessAt: Int64?
    var lastBackupId: String?
    var lastError: String?

    private enum CodingKeys: String, CodingKey {
        case lastAttemptAt = "last_attempt_at"
        case lastSuccessAt = "last_success_at"
        case lastBackupId = "last_backup_id"
        case lastError = "last_error"
    }
}

struct ServerBackupSummary: Codable, Identifiable, Sendable {
    var id: String
    var createdAt: Int64
    var reason: String
    var serverVersion: String
    var passwordCount: Int
    var deviceCount: Int
    var sizeBytes: Int64
    var sha256: String?
    var valid: Bool
    var error: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case reason
        case serverVersion = "server_version"
        case passwordCount = "password_count"
        case deviceCount = "device_count"
        case sizeBytes = "size_bytes"
        case sha256
        case valid
        case error
    }
}

struct ServerBackupStatus: Codable, Sendable {
    var policy: ServerBackupPolicy
    var state: ServerBackupRuntimeState
    var nextRunAt: Int64?
    var backupRoot: String
    var totalBytes: Int64
    var validCount: Int
    var brokenCount: Int
    var backups: [ServerBackupSummary]

    private enum CodingKeys: String, CodingKey {
        case policy
        case state
        case nextRunAt = "next_run_at"
        case backupRoot = "backup_root"
        case totalBytes = "total_bytes"
        case validCount = "valid_count"
        case brokenCount = "broken_count"
        case backups
    }
}

struct ServerBackupFile: Codable, Sendable {
    var path: String
    var mode: UInt32
    var size: Int64
    var sha256: String
    var dataBase64: String

    private enum CodingKeys: String, CodingKey {
        case path, mode, size, sha256
        case dataBase64 = "data_b64"
    }
}

struct ServerBackupDocument: Codable, Sendable {
    var format: String
    var version: Int
    var id: String
    var createdAt: Int64
    var reason: String
    var serverVersion: String
    var passwordCount: Int
    var deviceCount: Int
    var files: [ServerBackupFile]

    private enum CodingKeys: String, CodingKey {
        case format, version, id, reason, files
        case createdAt = "created_at"
        case serverVersion = "server_version"
        case passwordCount = "password_count"
        case deviceCount = "device_count"
    }
}

struct ServerAdminClientTransferPayload: Codable, Sendable {
    var format: String
    var version: Int
    var createdAt: Int64
    var password: String
    var label: String?
    var vkHash: String?
    var expiresAt: Int64
    var deactivated: Bool
}

struct ServerAdminClientsExportPayload: Codable, Sendable {
    var format: String
    var version: Int
    var exportedAt: Int64
    var transport: String
    var clients: [ServerAdminClientInfo]
}

struct ServerAdminEnvelope: Decodable, Sendable {
    var ok: Bool
    var status: String
    var message: String
    var output: String?
    var state: ServerAdminStatePayload?
}

struct ServerAdminCreateRequest: Sendable {
    var label: String
    var vkHash: String
    var ports: String
    var days: Int
    var clientPassword: String
}

struct ServerAdminUpdateRequest: Sendable {
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
    case backupStatus = "backup-status"
    case backupConfigure = "backup-configure"
    case backupCreate = "backup-create"
    case backupVerify = "backup-verify"
    case backupExport = "backup-export"
    case backupDelete = "backup-delete"
}

private struct ServerAdminBridgeRequest: Encodable, Sendable {
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
    var backupID: String?
    var backupEnabled: Bool?
    var backupInterval: Int?
    var backupKeep: Int?
}

private struct CSQTTAdminBridgeRequest: Encodable, Sendable {
    var action: String
    var host: String
    var user: String
    var password: String
    var port: Int
    var webPort: Int
    var webUser: String
    var webPassword: String
    var clientPassword: String?
    var label: String?
    var ports: String?
    var days: Int?
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

extension ServerAdminClientsExportPayload {
    private enum CodingKeys: String, CodingKey {
        case format
        case version
        case exportedAt = "exported_at"
        case transport
        case clients
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
        let normalizedClientPassword = clientPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedNewPassword = newPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await call(ServerAdminBridgeRequest(
            action: ServerAdminAction.setPassword.rawValue,
            host: target.host,
            user: target.user,
            password: target.password,
            port: target.port,
            mainPassword: target.mainPassword,
            clientPassword: normalizedClientPassword,
            newPassword: normalizedNewPassword
        ))
    }

    static func setExpiry(_ target: ServerAdminTarget, clientPassword: String, days: Int?, expiresAt: Int64?) async throws -> ServerAdminEnvelope {
        let normalizedClientPassword = clientPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await call(ServerAdminBridgeRequest(
            action: ServerAdminAction.setExpiry.rawValue,
            host: target.host,
            user: target.user,
            password: target.password,
            port: target.port,
            mainPassword: target.mainPassword,
            clientPassword: normalizedClientPassword,
            days: days,
            expiresAt: expiresAt
        ))
    }

    static func run(_ action: ServerAdminAction, target: ServerAdminTarget, clientPassword: String) async throws -> ServerAdminEnvelope {
        let normalizedClientPassword = clientPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await call(ServerAdminBridgeRequest(
            action: action.rawValue,
            host: target.host,
            user: target.user,
            password: target.password,
            port: target.port,
            mainPassword: target.mainPassword,
            clientPassword: normalizedClientPassword
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

    static func backupStatus(_ target: ServerAdminTarget) async throws -> ServerBackupStatus {
        let response = try await backupCall(target, action: .backupStatus)
        guard let status = response.state?.backupStatus else {
            throw NSError(domain: "ServerAdminBridge", code: 20, userInfo: [NSLocalizedDescriptionKey: "Server did not return backup status."])
        }
        return status
    }

    static func configureBackups(_ target: ServerAdminTarget, enabled: Bool, intervalHours: Int, retentionCount: Int) async throws -> ServerBackupStatus {
        let response = try await backupCall(target, action: .backupConfigure, enabled: enabled, intervalHours: intervalHours, retentionCount: retentionCount)
        guard let status = response.state?.backupStatus else {
            throw NSError(domain: "ServerAdminBridge", code: 21, userInfo: [NSLocalizedDescriptionKey: "Server did not return updated backup status."])
        }
        return status
    }

    static func createBackup(_ target: ServerAdminTarget) async throws -> ServerAdminEnvelope {
        try await backupCall(target, action: .backupCreate)
    }

    static func verifyBackup(_ target: ServerAdminTarget, id: String) async throws -> ServerAdminEnvelope {
        try await backupCall(target, action: .backupVerify, id: id)
    }

    static func deleteBackup(_ target: ServerAdminTarget, id: String) async throws -> ServerAdminEnvelope {
        try await backupCall(target, action: .backupDelete, id: id)
    }

    static func exportBackup(_ target: ServerAdminTarget, id: String) async throws -> String {
        let response = try await backupCall(target, action: .backupExport, id: id)
        guard let document = response.state?.backupDocument else {
            throw NSError(domain: "ServerAdminBridge", code: 22, userInfo: [NSLocalizedDescriptionKey: "Server did not return the backup document."])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "ServerAdminBridge", code: 23, userInfo: [NSLocalizedDescriptionKey: "Failed to encode the backup document."])
        }
        return text
    }

    private static func backupCall(
        _ target: ServerAdminTarget,
        action: ServerAdminAction,
        id: String? = nil,
        enabled: Bool? = nil,
        intervalHours: Int? = nil,
        retentionCount: Int? = nil
    ) async throws -> ServerAdminEnvelope {
        try await call(ServerAdminBridgeRequest(
            action: action.rawValue,
            host: target.host,
            user: target.user,
            password: target.password,
            port: target.port,
            mainPassword: target.mainPassword,
            backupID: id,
            backupEnabled: enabled,
            backupInterval: intervalHours,
            backupKeep: retentionCount
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

    static func exportClients(_ clients: [ServerAdminClientInfo]) throws -> String {
        let payload = ServerAdminClientsExportPayload(
            format: "wdtt-clients",
            version: 1,
            exportedAt: Int64(Date().timeIntervalSince1970 * 1000),
            transport: "wdtt",
            clients: clients
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "ServerAdminBridge", code: 8, userInfo: [NSLocalizedDescriptionKey: "Failed to encode clients export JSON."])
        }
        return text
    }

    static func importClient(_ target: ServerAdminTarget, transferText: String, defaultPorts: String = "56000,56001,9000") async throws -> ServerAdminEnvelope {
        let data = Data(transferText.utf8)
        let decoder = JSONDecoder()

        if let payload = try? decoder.decode(ServerAdminClientTransferPayload.self, from: data) {
            guard payload.format == "wdtt-plus-client", payload.version == 1 else {
                throw NSError(domain: "ServerAdminBridge", code: 6, userInfo: [NSLocalizedDescriptionKey: "Unsupported client transfer format."])
            }
            return try await importSingleClient(target, payload: payload, defaultPorts: defaultPorts)
        }

        if let payload = try? decoder.decode(ServerAdminClientsExportPayload.self, from: data) {
            guard payload.version == 1, payload.transport == "wdtt", payload.format == "wdtt-clients" else {
                throw NSError(domain: "ServerAdminBridge", code: 9, userInfo: [NSLocalizedDescriptionKey: "Unsupported clients export format."])
            }
            guard !payload.clients.isEmpty else {
                throw NSError(domain: "ServerAdminBridge", code: 10, userInfo: [NSLocalizedDescriptionKey: "The selected clients export file is empty."])
            }
            return try await importClients(target, clients: payload.clients, defaultPorts: defaultPorts)
        }

        throw NSError(domain: "ServerAdminBridge", code: 11, userInfo: [NSLocalizedDescriptionKey: "Unsupported client import file."])
    }

    private static func importSingleClient(
        _ target: ServerAdminTarget,
        payload: ServerAdminClientTransferPayload,
        defaultPorts: String
    ) async throws -> ServerAdminEnvelope {
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

    private static func importClients(
        _ target: ServerAdminTarget,
        clients: [ServerAdminClientInfo],
        defaultPorts: String
    ) async throws -> ServerAdminEnvelope {
        let now = Int64(Date().timeIntervalSince1970)
        var importedCount = 0

        for client in clients {
            let expiresAt = client.expiresAt ?? 0
            if expiresAt > 0, expiresAt <= now {
                continue
            }

            let response = try await create(target, request: ServerAdminCreateRequest(
                label: client.label ?? "",
                vkHash: client.vkHash ?? "",
                ports: client.ports?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? client.ports! : defaultPorts,
                days: 0,
                clientPassword: client.password
            ))

            if expiresAt > 0 {
                _ = try await setExpiry(target, clientPassword: client.password, days: nil, expiresAt: expiresAt)
            }
            if !client.isActive {
                _ = try await run(.deactivate, target: target, clientPassword: client.password)
            }
            importedCount += 1

            if !response.ok {
                throw NSError(domain: "ServerAdminBridge", code: 12, userInfo: [NSLocalizedDescriptionKey: response.message])
            }
        }

        return ServerAdminEnvelope(
            ok: true,
            status: "success",
            message: "Imported \(importedCount) clients.",
            output: nil,
            state: nil
        )
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
            let envelope = try decoder.decode(ServerAdminEnvelope.self, from: responseData)
            if !envelope.ok {
                throw NSError(domain: "ServerAdminBridge", code: 4, userInfo: [NSLocalizedDescriptionKey: localizedServerAdminMessage(envelope.message)])
            }
            return envelope
        }.value
    }

    nonisolated private static func localizedServerAdminMessage(_ message: String) -> String {
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

enum CSQTTAdminAction: String {
    case list
    case create
    case update
    case delete
    case unbind
    case activate
    case deactivate
}

enum CSQTTAdminBridge {
    static func list(_ target: CSQTTAdminTarget) async throws -> [ServerAdminClientInfo] {
        let response = try await call(CSQTTAdminBridgeRequest(
            action: CSQTTAdminAction.list.rawValue,
            host: target.host,
            user: target.user,
            password: target.password,
            port: target.port,
            webPort: target.webPort,
            webUser: target.webUser,
            webPassword: target.webPassword
        ))
        return response.state?.passwords ?? []
    }

    static func create(_ target: CSQTTAdminTarget, label: String, ports: String, days: Int) async throws -> ServerAdminEnvelope {
        try await call(CSQTTAdminBridgeRequest(
            action: CSQTTAdminAction.create.rawValue,
            host: target.host,
            user: target.user,
            password: target.password,
            port: target.port,
            webPort: target.webPort,
            webUser: target.webUser,
            webPassword: target.webPassword,
            label: label.isEmpty ? nil : label,
            ports: ports.isEmpty ? nil : ports,
            days: days
        ))
    }

    static func update(_ target: CSQTTAdminTarget, clientPassword: String, label: String, ports: String, days: Int) async throws -> ServerAdminEnvelope {
        try await call(CSQTTAdminBridgeRequest(
            action: CSQTTAdminAction.update.rawValue,
            host: target.host,
            user: target.user,
            password: target.password,
            port: target.port,
            webPort: target.webPort,
            webUser: target.webUser,
            webPassword: target.webPassword,
            clientPassword: clientPassword,
            label: label.isEmpty ? nil : label,
            ports: ports.isEmpty ? nil : ports,
            days: days
        ))
    }

    static func run(_ action: CSQTTAdminAction, target: CSQTTAdminTarget, clientPassword: String) async throws -> ServerAdminEnvelope {
        try await call(CSQTTAdminBridgeRequest(
            action: action.rawValue,
            host: target.host,
            user: target.user,
            password: target.password,
            port: target.port,
            webPort: target.webPort,
            webUser: target.webUser,
            webPassword: target.webPassword,
            clientPassword: clientPassword
        ))
    }

    static func quickLink(_ target: CSQTTAdminTarget, client: ServerAdminClientInfo) -> String? {
        let ports = (client.ports?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? client.ports! : "46000,46001,0")
        let parts = ports.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let dtlsPort = parts.first.flatMap(Int.init) ?? 46000
        var components = URLComponents()
        components.scheme = "csqtt"
        components.user = client.password
        components.host = target.host
        components.port = dtlsPort
        if let label = client.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            components.queryItems = [URLQueryItem(name: "name", value: label)]
        }
        return components.url?.absoluteString
    }

    static func exportClients(_ clients: [ServerAdminClientInfo]) throws -> String {
        let payload = ServerAdminClientsExportPayload(
            format: "csqtt-clients",
            version: 1,
            exportedAt: Int64(Date().timeIntervalSince1970 * 1000),
            transport: "csqtt",
            clients: clients
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "CSQTTAdminBridge", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to encode clients export JSON."])
        }
        return text
    }

    private static func call(_ request: CSQTTAdminBridgeRequest) async throws -> ServerAdminEnvelope {
        try await Task.detached(priority: .userInitiated) {
            let data = try JSONEncoder().encode(request)
            guard let json = String(data: data, encoding: .utf8) else {
                throw NSError(domain: "CSQTTAdminBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode CSQTT admin request."])
            }
            let pointer = json.withCString {
                VBridgeWGCSQTTAdmin(UnsafeMutablePointer(mutating: $0))
            }
            guard let pointer else {
                throw NSError(domain: "CSQTTAdminBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "CSQTT admin bridge returned an empty response."])
            }
            defer { VBridgeWGFreeCString(pointer) }
            let responseJSON = String(cString: pointer)
            guard let responseData = responseJSON.data(using: .utf8) else {
                throw NSError(domain: "CSQTTAdminBridge", code: 3, userInfo: [NSLocalizedDescriptionKey: "CSQTT admin bridge returned invalid UTF-8."])
            }
            let decoder = JSONDecoder()
            let envelope = try decoder.decode(ServerAdminEnvelope.self, from: responseData)
            if !envelope.ok {
                throw NSError(domain: "CSQTTAdminBridge", code: 4, userInfo: [NSLocalizedDescriptionKey: localizedMessage(envelope.message)])
            }
            return envelope
        }.value
    }

    nonisolated private static func localizedMessage(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        case "invalid credentials":
            return "Invalid CSQTT web login or password."
        case "client password is empty":
            return "Client password is required."
        default:
            return trimmed
        }
    }
}
