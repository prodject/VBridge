import NetworkExtension

/// Builds a system routing policy without modifying the saved tunnel policy.
/// The VPN protocol must have includeAllNetworks disabled for bypass to work.
public enum VPNBypassRouting {
    public static func settings(from base: NEPacketTunnelNetworkSettings, bypass: Bool) -> NEPacketTunnelNetworkSettings {
        let settings = base.copy() as! NEPacketTunnelNetworkSettings
        settings.ipv4Settings = base.ipv4Settings?.copy() as? NEIPv4Settings
        settings.ipv6Settings = base.ipv6Settings?.copy() as? NEIPv6Settings
        if bypass {
            settings.ipv4Settings?.includedRoutes = []
            settings.ipv4Settings?.excludedRoutes = [NEIPv4Route.default()]
            settings.ipv6Settings?.includedRoutes = []
            settings.ipv6Settings?.excludedRoutes = [NEIPv6Route.default()]
            settings.dnsSettings = nil
            settings.proxySettings = nil
        }
        return settings
    }
}
