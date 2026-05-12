import Foundation

struct VPNProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var vkLink: String
    var peerAddr: String
    var listenAddr: String
    var nValue: Int
    var credsGroupSize: Int
    var wgQuickConfig: String
    var turnHost: String
    var turnPort: String
    var useUdp: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case vkLink
        case peerAddr
        case listenAddr
        case nValue
        case credsGroupSize
        case wgQuickConfig
        case turnHost
        case turnPort
        case useUdp
    }

    init(
        id: UUID = UUID(),
        name: String = "",
        vkLink: String = "",
        peerAddr: String = "",
        listenAddr: String = "127.0.0.1:9000",
        nValue: Int = 10,
        credsGroupSize: Int = 12,
        wgQuickConfig: String = "",
        turnHost: String = "",
        turnPort: String = "",
        useUdp: Bool = true
    ) {
        self.id = id
        self.name = name
        self.vkLink = vkLink
        self.peerAddr = peerAddr
        self.listenAddr = listenAddr
        self.nValue = nValue
        self.credsGroupSize = credsGroupSize
        self.wgQuickConfig = wgQuickConfig
        self.turnHost = turnHost
        self.turnPort = turnPort
        self.useUdp = useUdp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        vkLink = try container.decodeIfPresent(String.self, forKey: .vkLink) ?? ""
        peerAddr = try container.decodeIfPresent(String.self, forKey: .peerAddr) ?? ""
        listenAddr = try container.decodeIfPresent(String.self, forKey: .listenAddr) ?? "127.0.0.1:9000"
        nValue = try container.decodeIfPresent(Int.self, forKey: .nValue) ?? 10
        credsGroupSize = max(try container.decodeIfPresent(Int.self, forKey: .credsGroupSize) ?? 12, 1)
        wgQuickConfig = try container.decodeIfPresent(String.self, forKey: .wgQuickConfig) ?? ""
        turnHost = try container.decodeIfPresent(String.self, forKey: .turnHost) ?? ""
        turnPort = try container.decodeIfPresent(String.self, forKey: .turnPort) ?? ""
        useUdp = try container.decodeIfPresent(Bool.self, forKey: .useUdp) ?? true
    }
}
