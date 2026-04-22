import SwiftUI
import Foundation
import Darwin

struct GlobalSettingsView: View {
    @AppStorage("excludeAPNs") private var excludeAPNs = false
    @AppStorage("excludeCellularServices") private var excludeCellularServices = false
    @AppStorage("excludeLocalNetworks") private var excludeLocalNetworks = true
    @AppStorage("manualCaptcha") private var manualCaptcha = false
    @AppStorage("autoUpdateEnabled") private var autoUpdateEnabled = true
    @AppStorage("appTheme") private var appTheme = "system"
    @AppStorage("tetherProxyEnabled") private var tetherProxyEnabled = false
    @AppStorage("tetherProxyPort") private var tetherProxyPort = 9000

    var body: some View {
        Form {
            Section(header: Text("General")) {
                NavigationLink(destination: AboutView()) {
                    Label(
                        title: { Text("About") },
                        icon: { Image(systemName: "info.circle").foregroundColor(.secondary) }
                    )
                }
                
                NavigationLink(destination: LogView()) {
                    Label(
                        title: { Text("Logs") },
                        icon: { Image(systemName: "doc.text.magnifyingglass").foregroundColor(.secondary) }
                    )
                }
            }

            Section(header: Text("Routing")) {
                Toggle(isOn: $excludeLocalNetworks) {
                    VStack(alignment: .leading) {
                        Text("Allow LAN Access")
                        Text("Access local network devices without routing through VPN")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Toggle(isOn: $excludeAPNs) {
                    VStack(alignment: .leading) {
                        Text("Bypass APNs")
                        Text("Send push notifications directly, bypassing the tunnel")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Toggle(isOn: $excludeCellularServices) {
                    VStack(alignment: .leading) {
                        Text("Bypass Cellular")
                        Text("Exclude calls, SMS, and voicemail from the tunnel")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section(header: Text("Captcha")) {
                Toggle(isOn: $manualCaptcha) {
                    VStack(alignment: .leading) {
                        Text("Manual Captcha")
                        Text("Disable automatic captcha solving and require manual solving flow")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section(header: Text("Updates")) {
                Toggle(isOn: $autoUpdateEnabled) {
                    VStack(alignment: .leading) {
                        Text("Autoupdate")
                        Text("Check GitHub Releases and offer download when a newer version is available")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section(header: Text("Experimental")) {
                Toggle(isOn: $tetherProxyEnabled) {
                    VStack(alignment: .leading) {
                        Text("Tether proxy")
                        Text("Bind proxy on all interfaces so clients in the same LAN can connect")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if tetherProxyEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        if let address = LocalNetworkAddressResolver.currentIPv4Address() {
                            Text("Connect from LAN:")
                                .font(.subheadline.weight(.semibold))
                            Text("\(address):\(tetherProxyPort)")
                                .font(.caption.monospaced())
                                .foregroundColor(.secondary)
                            Text("Use this as HTTP/SOCKS proxy endpoint on another device in the same Wi-Fi.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Connect from LAN:")
                                .font(.subheadline.weight(.semibold))
                            Text("IP not detected. Connect iPhone to Wi-Fi and reopen this screen.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section(header: Text("Appearance")) {
                Picker("Theme", selection: $appTheme) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private enum LocalNetworkAddressResolver {
    static func currentIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr = firstAddr
        while true {
            let interface = ptr.pointee
            guard let sockaddrPointer = interface.ifa_addr else {
                guard let next = interface.ifa_next else { break }
                ptr = next
                continue
            }

            let family = sockaddrPointer.pointee.sa_family
            if family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(
                        sockaddrPointer,
                        socklen_t(sockaddrPointer.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                    let address = String(cString: hostname)
                    if !address.isEmpty { return address }
                }
            }
            guard let next = interface.ifa_next else { break }
            ptr = next
        }
        return nil
    }
}
