public enum TrustedWiFiFlowPolicy {
    /// An unreadable or unknown SSID is never a trusted network.
    public static func shouldBypass(enabled: Bool, flowConnect: Bool,
                                    trustedSSIDs: Set<String>, currentSSID: String?) -> Bool {
        guard enabled, flowConnect, let currentSSID else { return false }
        return trustedSSIDs.contains(currentSSID)
    }
}
