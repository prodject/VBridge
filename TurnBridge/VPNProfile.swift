import Foundation

struct SeededTURNCredentials: Codable, Equatable {
    let address: String
    let username: String
    let password: String

    var providerConfiguration: [String: String] {
        [
            "address": address,
            "username": username,
            "password": password
        ]
    }
}

enum VPNTransportMode: String, Codable, CaseIterable, Identifiable {
    case wg
    case srtpCommunity
    case wdtt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wg:
            return "WG"
        case .srtpCommunity:
            return "SRTP-Community"
        case .wdtt:
            return "WDTT"
        }
    }
}

struct VPNProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var transportMode: VPNTransportMode
    var vkLink: String
    var peerAddr: String
    var listenAddr: String
    var nValue: Int
    var credsGroupSize: Int
    var wgQuickConfig: String
    var turnHost: String
    var turnPort: String
    var useUdp: Bool
    var wrapKeyHex: String
    var wdttPassword: String
    var wdttClientKey: String
    var wdttServerKey: String

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case transportMode
        case vkLink
        case peerAddr
        case listenAddr
        case nValue
        case credsGroupSize
        case wgQuickConfig
        case turnHost
        case turnPort
        case useUdp
        case wrapKeyHex
        case wdttPassword
        case wdttClientKey
        case wdttServerKey
    }

    init(
        id: UUID = UUID(),
        name: String = "",
        transportMode: VPNTransportMode = .wg,
        vkLink: String = "",
        peerAddr: String = "",
        listenAddr: String = "127.0.0.1:9000",
        nValue: Int = 30,
        credsGroupSize: Int = 12,
        wgQuickConfig: String = "",
        turnHost: String = "",
        turnPort: String = "",
        useUdp: Bool = false,
        wrapKeyHex: String = "",
        wdttPassword: String = "",
        wdttClientKey: String = "",
        wdttServerKey: String = ""
    ) {
        self.id = id
        self.name = name
        self.transportMode = transportMode
        self.vkLink = vkLink
        self.peerAddr = peerAddr
        self.listenAddr = listenAddr
        self.nValue = nValue
        self.credsGroupSize = credsGroupSize
        self.wgQuickConfig = wgQuickConfig
        self.turnHost = turnHost
        self.turnPort = turnPort
        self.useUdp = useUdp
        self.wrapKeyHex = wrapKeyHex
        self.wdttPassword = wdttPassword
        self.wdttClientKey = wdttClientKey
        self.wdttServerKey = wdttServerKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        transportMode = try container.decodeIfPresent(VPNTransportMode.self, forKey: .transportMode) ?? .wg
        vkLink = try container.decodeIfPresent(String.self, forKey: .vkLink) ?? ""
        peerAddr = try container.decodeIfPresent(String.self, forKey: .peerAddr) ?? ""
        listenAddr = try container.decodeIfPresent(String.self, forKey: .listenAddr) ?? "127.0.0.1:9000"
        nValue = try container.decodeIfPresent(Int.self, forKey: .nValue) ?? 30
        credsGroupSize = max(try container.decodeIfPresent(Int.self, forKey: .credsGroupSize) ?? 12, 1)
        wgQuickConfig = try container.decodeIfPresent(String.self, forKey: .wgQuickConfig) ?? ""
        turnHost = try container.decodeIfPresent(String.self, forKey: .turnHost) ?? ""
        turnPort = try container.decodeIfPresent(String.self, forKey: .turnPort) ?? ""
        useUdp = try container.decodeIfPresent(Bool.self, forKey: .useUdp) ?? false
        wrapKeyHex = try container.decodeIfPresent(String.self, forKey: .wrapKeyHex) ?? ""
        wdttPassword = try container.decodeIfPresent(String.self, forKey: .wdttPassword) ?? ""
        wdttClientKey = try container.decodeIfPresent(String.self, forKey: .wdttClientKey) ?? ""
        wdttServerKey = try container.decodeIfPresent(String.self, forKey: .wdttServerKey) ?? ""
    }
}
