import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

func settings(_ link: String) throws -> [String: Any] {
    let url = URLComponents(string: link)!
    require(url.scheme == "vkturnproxy" && url.host == "import", "Wrong import URL")
    let raw = url.queryItems!.first { $0.name == "data" }!.value!
    require(!raw.contains("+") && !raw.contains("/") && !raw.contains("="), "Base64 must be URL-safe without padding")
    var base64 = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    let payload = try JSONSerialization.jsonObject(with: Data(base64Encoded: base64)!) as! [String: Any]
    require(payload["version"] as? Int == 1 && payload["type"] as? String == "connection", "Wrong ConnectionLink schema")
    return payload["settings"] as! [String: Any]
}

func rejects(_ action: () throws -> Void) {
    do { try action(); preconditionFailure("Expected an invalid link to be rejected") }
    catch { require(error is ExternalClientLinks.LinkError, "Unexpected error") }
}

let classic = try ExternalClientLinks.wdtt(host: "203.0.113.1", ports: "56000,56001,9000", password: "secret", hashes: "https://vk.com/call/join/hash1\nhash2", name: "Client", legacy: true)
require(classic == "wdtt://203.0.113.1:56000:56001:9000:secret:hash1,hash2", "Classic positional format changed")
let wdtt = try settings(ExternalClientLinks.wdtt(host: "2001:db8::1", ports: "56000,56001,9000", password: "secret:with#symbols", hashes: "hash1,hash2", name: "Клиент", legacy: false))
require(wdtt["peerAddress"] as? String == "[2001:db8::1]:56000", "IPv6 endpoint malformed")
require(wdtt["useWrapA"] as? Bool == true && wdtt["useSrtp"] as? Bool == false, "Wrong WDTT mode")
require(wdtt["wrapAPassword"] as? String == "secret:with#symbols", "Password changed")
require(wdtt["vkLink"] as? String == "https://vk.ru/call/join/hash1\nhttps://vk.ru/call/join/hash2", "Call list changed")
require(wdtt["serverName"] as? String == "Клиент", "Unicode label lost")
require(wdtt["deviceID"] == nil && wdtt["privateKey"] == nil, "Device identity must never be shared")

let key = Data(repeating: 7, count: 32).base64EncodedString()
let config = """
[Interface]
PrivateKey = \(key)
Address = 10.66.66.2/32
DNS = 1.1.1.1, 8.8.8.8
[Peer]
PublicKey = \(key)
PresharedKey = \(key)
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 127.0.0.1:9000
"""
let srtp = try settings(ExternalClientLinks.srtp(host: "vpn.example.com", port: 57000, config: config, calls: "hash", name: "SRTP"))
require(srtp["peerAddress"] as? String == "vpn.example.com:57000", "Loopback WG endpoint leaked into SRTP server")
require(srtp["useSrtp"] as? Bool == true && srtp["useWrapA"] as? Bool == false, "Wrong SRTP mode")
require(srtp["privateKey"] as? String == key && srtp["peerPublicKey"] as? String == key && srtp["presharedKey"] as? String == key, "Keys or base64 padding lost")
require(srtp["tunnelAddress"] as? String == "10.66.66.2/32", "Tunnel address lost")
require(srtp["dnsServers"] as? String == "1.1.1.1, 8.8.8.8", "DNS changed")
require(srtp["allowedIPs"] as? String == "0.0.0.0/0, ::/0", "AllowedIPs changed")
let noPSK = config.replacingOccurrences(of: "PresharedKey = \(key)\n", with: "")
let unkeyed = try settings(ExternalClientLinks.srtp(host: "203.0.113.1", port: 57000, config: noPSK, calls: "hash", name: "SRTP"))
require(unkeyed["presharedKey"] as? String == "", "An absent PSK must clear a stale imported PSK")

rejects { _ = try ExternalClientLinks.wdtt(host: "2001:db8::1", ports: "56000,56001,9000", password: "secret", hashes: "hash", name: "", legacy: true) }
rejects { _ = try ExternalClientLinks.wdtt(host: "host", ports: "56000,56001,9000", password: "secret:colon", hashes: "hash", name: "", legacy: true) }
rejects { _ = try ExternalClientLinks.wdtt(host: "host", ports: "0,56001,9000", password: "secret", hashes: "hash", name: "", legacy: false) }
rejects { _ = try ExternalClientLinks.wdtt(host: "host", ports: "56000,56001,9000", password: "secret", hashes: "", name: "", legacy: false) }
rejects { _ = try ExternalClientLinks.srtp(host: "host", port: 57000, config: config, calls: "", name: "") }
rejects { _ = try ExternalClientLinks.srtp(host: "host", port: 57000, config: config + "\n[Peer]\nPublicKey = \(key)", calls: "hash", name: "") }
rejects { _ = try ExternalClientLinks.srtp(host: "host", port: 57000, config: config.replacingOccurrences(of: key, with: "bad-key"), calls: "hash", name: "") }
rejects { _ = try ExternalClientLinks.callLinks("https://example.com/call/join/hash") }
print("External client link checks passed")
