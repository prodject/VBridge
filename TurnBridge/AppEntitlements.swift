import Foundation

struct AppEntitlements: Sendable {
    let applicationIdentifier: String?
    let teamIdentifier: String?
    let applicationGroups: [String]
    let networkExtensionModes: [String]
    let error: String?

    static let current: AppEntitlements = load()

    func hasAppGroup(_ identifier: String) -> Bool {
        applicationGroups.contains(identifier)
    }

    var hasPacketTunnelProvider: Bool {
        networkExtensionModes.contains("packet-tunnel-provider")
    }

    var effectiveTeam: String? {
        if let teamIdentifier, !teamIdentifier.isEmpty {
            return teamIdentifier
        }
        guard let applicationIdentifier,
              let dot = applicationIdentifier.firstIndex(of: ".") else {
            return nil
        }
        return String(applicationIdentifier[..<dot])
    }

    static func appGroupDiagnosis(required: String) -> String {
        let entitlements = current
        if let error = entitlements.error {
            return "Could not read this build's entitlements (\(error)). Cannot tell whether \(required) was granted."
        }

        let team = entitlements.effectiveTeam ?? "unknown team"
        let groups = entitlements.applicationGroups.isEmpty
            ? "none"
            : entitlements.applicationGroups.joined(separator: ", ")

        if entitlements.hasAppGroup(required) {
            return "This build is entitled to \(required) (team \(team)). The shared container should be available."
        }

        return """
        This build is NOT entitled to \(required).
        Signed by team \(team)\(entitlements.applicationIdentifier.map { " (app id \($0))" } ?? "").
        App Groups it does have: \(groups).
        That means the IPA was re-signed by a third party, so the original shared container cannot be preserved.
        Shared logging between app and tunnel, TURN credential cache, shared captcha state, widgets and extension statistics are disabled in this build.
        The VPN may still work, but the app cannot rely on App Group IPC.
        """
    }
}

private extension AppEntitlements {
    static func load() -> AppEntitlements {
        guard let executablePath = Bundle.main.executablePath else {
            return AppEntitlements(
                applicationIdentifier: nil,
                teamIdentifier: nil,
                applicationGroups: [],
                networkExtensionModes: [],
                error: "missing executable path"
            )
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: executablePath))
            guard let plist = extractEntitlementsPlist(from: data) else {
                return AppEntitlements(
                    applicationIdentifier: nil,
                    teamIdentifier: nil,
                    applicationGroups: [],
                    networkExtensionModes: [],
                    error: "entitlements plist not found"
                )
            }

            return AppEntitlements(
                applicationIdentifier: plist["application-identifier"] as? String,
                teamIdentifier: plist["com.apple.developer.team-identifier"] as? String,
                applicationGroups: plist["com.apple.security.application-groups"] as? [String] ?? [],
                networkExtensionModes: plist["com.apple.developer.networking.networkextension"] as? [String] ?? [],
                error: nil
            )
        } catch {
            return AppEntitlements(
                applicationIdentifier: nil,
                teamIdentifier: nil,
                applicationGroups: [],
                networkExtensionModes: [],
                error: error.localizedDescription
            )
        }
    }

    static func extractEntitlementsPlist(from data: Data) -> [String: Any]? {
        let xmlMarker = Data("<?xml".utf8)
        let endMarker = Data("</plist>".utf8)
        var searchRange = data.startIndex..<data.endIndex

        while let xmlStart = data.range(of: xmlMarker, in: searchRange) {
            guard let xmlEnd = data.range(of: endMarker, in: xmlStart.lowerBound..<data.endIndex) else {
                break
            }

            let plistRange = xmlStart.lowerBound..<xmlEnd.upperBound
            let plistData = data.subdata(in: plistRange)

            if let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
               plist["application-identifier"] != nil || plist["com.apple.security.application-groups"] != nil {
                return plist
            }

            searchRange = xmlEnd.upperBound..<data.endIndex
        }

        return nil
    }
}
