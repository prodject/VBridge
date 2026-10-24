import Foundation
import Network
import NetworkExtension
import WireGuardKit

/// Runs in the packet tunnel process, independently of the app's foreground UI.
final class TrustedWiFiFlowMonitor {
    var onTrustedNetwork: ((Bool) -> Void)?
    private var enabled = false
    private var ssids = Set<String>()
    private var monitor: NWPathMonitor?
    private var timer: DispatchSourceTimer?
    private var wifiAvailable = false
    private var generation = 0
    private var lookupRevision = 0
    private var reportedUnreadableSSID = false

    // All state and callbacks are confined to the main queue.
    func configure(_ settings: [String: Any]) {
        stop()
        enabled = settings["enabled"] as? Bool == true && settings["flowConnect"] as? Bool == true
        ssids = Set(settings["ssids"] as? [String] ?? [])
        onTrustedNetwork?(false)
        guard enabled, !ssids.isEmpty else {
            return
        }
#if os(iOS) && !targetEnvironment(macCatalyst)
        let pathMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
        monitor = pathMonitor
        let currentGeneration = generation
        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self, self.generation == currentGeneration else { return }
                self.wifiAvailable = path.status == .satisfied
                self.refresh()
            }
        }
        pathMonitor.start(queue: .main)
        // Roaming between SSIDs need not change the path's interface type.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 5, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.refresh() }
        self.timer = timer
        timer.resume()
#else
        onTrustedNetwork?(false)
#endif
    }

    private func refresh() {
        guard enabled else { return }
        lookupRevision += 1
        let revision = lookupRevision
        guard wifiAvailable else {
            onTrustedNetwork?(false)
            return
        }
#if os(iOS) && !targetEnvironment(macCatalyst)
        let currentGeneration = generation
        NEHotspotNetwork.fetchCurrent { [weak self] network in
            guard let self, self.generation == currentGeneration, self.lookupRevision == revision else { return }
            if network == nil && !self.reportedUnreadableSSID {
                self.reportedUnreadableSSID = true
                SharedLogger.warning("Flow connect: Wi-Fi SSID is unavailable; automatic bypass stays off. Check Access Wi-Fi Information in the signing profile.", source: .tunnel)
            } else if network != nil {
                self.reportedUnreadableSSID = false
            }
            // Never infer trust from an unreadable SSID or an old Wi-Fi path.
            let trusted = self.wifiAvailable && TrustedWiFiFlowPolicy.shouldBypass(
                enabled: self.enabled, flowConnect: true, trustedSSIDs: self.ssids, currentSSID: network?.ssid)
            self.onTrustedNetwork?(trusted)
        }
#endif
    }

    func stop() {
        generation += 1
        enabled = false
        wifiAvailable = false
        reportedUnreadableSSID = false
        monitor?.cancel()
        monitor = nil
        timer?.cancel()
        timer = nil
    }
}
