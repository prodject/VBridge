import XCTest
import NetworkExtension
@testable import WireGuardKit

final class VPNBypassRoutingTests: XCTestCase {
    func testBypassReleasesBothAddressFamiliesAndDNS() {
        let base = makeSettings()
        let bypass = VPNBypassRouting.settings(from: base, bypass: true)
        XCTAssertEqual(bypass.ipv4Settings?.includedRoutes?.count, 0)
        XCTAssertEqual(bypass.ipv6Settings?.includedRoutes?.count, 0)
        XCTAssertEqual(bypass.ipv4Settings?.excludedRoutes?.first?.destinationAddress, "0.0.0.0")
        XCTAssertEqual(bypass.ipv4Settings?.excludedRoutes?.first?.destinationSubnetMask, "0.0.0.0")
        XCTAssertEqual(bypass.ipv6Settings?.excludedRoutes?.first?.destinationAddress, "::")
        XCTAssertEqual(bypass.ipv6Settings?.excludedRoutes?.first?.destinationNetworkPrefixLength, 0)
        XCTAssertNil(bypass.dnsSettings)
        XCTAssertNil(bypass.proxySettings)
        XCTAssertEqual(bypass.ipv4Settings?.addresses, base.ipv4Settings?.addresses)
        XCTAssertEqual(bypass.ipv6Settings?.addresses, base.ipv6Settings?.addresses)
        XCTAssertEqual(bypass.mtu, base.mtu)
    }

    func testReturningToVPNPreservesSplitRoutesAndDNSAcrossRepeatedChanges() {
        let base = makeSettings()
        for _ in 0..<3 {
            _ = VPNBypassRouting.settings(from: base, bypass: true)
            let restored = VPNBypassRouting.settings(from: base, bypass: false)
            XCTAssertEqual(restored.ipv4Settings?.includedRoutes?.map(\.destinationAddress), ["10.20.0.0"])
            XCTAssertEqual(restored.ipv4Settings?.excludedRoutes?.map(\.destinationAddress), ["192.168.0.0"])
            XCTAssertEqual(restored.ipv6Settings?.includedRoutes?.map(\.destinationAddress), ["fd20::"])
            XCTAssertEqual(restored.dnsSettings?.servers, ["10.20.0.1"])
            XCTAssertEqual(restored.dnsSettings?.matchDomains, ["example.com"])
            XCTAssertNotNil(restored.proxySettings)
        }
    }

    func testIPv4OnlyTunnelDoesNotAcquireAnIPv6Interface() {
        let base = makeSettings()
        base.ipv6Settings = nil
        XCTAssertNil(VPNBypassRouting.settings(from: base, bypass: true).ipv6Settings)
        XCTAssertNil(VPNBypassRouting.settings(from: base, bypass: false).ipv6Settings)
    }

    private func makeSettings() -> NEPacketTunnelNetworkSettings {
        let base = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "203.0.113.1")
        base.ipv4Settings = NEIPv4Settings(addresses: ["10.20.0.2"], subnetMasks: ["255.255.255.0"])
        base.ipv4Settings?.includedRoutes = [NEIPv4Route(destinationAddress: "10.20.0.0", subnetMask: "255.255.0.0")]
        base.ipv4Settings?.excludedRoutes = [NEIPv4Route(destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0")]
        base.ipv6Settings = NEIPv6Settings(addresses: ["fd20::2"], networkPrefixLengths: [64])
        base.ipv6Settings?.includedRoutes = [NEIPv6Route(destinationAddress: "fd20::", networkPrefixLength: 64)]
        base.dnsSettings = NEDNSSettings(servers: ["10.20.0.1"])
        base.dnsSettings?.matchDomains = ["example.com"]
        base.proxySettings = NEProxySettings()
        base.mtu = 1280
        return base
    }
}
