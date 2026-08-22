import Foundation

struct UpdateInfo: Equatable {
    let latestVersion: String
    let releaseURL: URL
    let assetURL: URL
    let assetFileName: String
    let assetKind: String
}

enum UpdateChecker {
    private static let releasesURL = URL(string: "https://api.github.com/repos/prodject/VBridge/releases?per_page=20")!

    static func checkForUpdate(currentVersion: String) async -> UpdateInfo? {
        guard let current = parseVersion(currentVersion) else {
            SharedLogger.warning("[Update] Failed to parse current version: \(currentVersion)")
            return nil
        }

        var request = URLRequest(url: releasesURL)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                SharedLogger.warning("[Update] Invalid GitHub response")
                return nil
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                SharedLogger.warning("[Update] GitHub API returned HTTP \(httpResponse.statusCode)")
                return nil
            }

            let decoder = JSONDecoder()
            let releases = try decoder.decode([GitHubRelease].self, from: data)
            guard let latest = latestRelease(from: releases) else { return nil }
            guard latest.version > current else { return nil }

            return UpdateInfo(
                latestVersion: latest.version.display,
                releaseURL: latest.url,
                assetURL: latest.asset.url,
                assetFileName: latest.asset.name,
                assetKind: updateAssetKind
            )
        } catch {
            SharedLogger.warning("[Update] Check failed: \(error.localizedDescription)")
            return nil
        }
    }

    nonisolated private static var updateAssetKind: String {
#if targetEnvironment(macCatalyst)
        return "DMG"
#else
        return "IPA"
#endif
    }

    nonisolated private static var updateAssetExtension: String {
#if targetEnvironment(macCatalyst)
        return ".dmg"
#else
        return ".ipa"
#endif
    }

    nonisolated private static func latestRelease(from releases: [GitHubRelease]) -> (version: AppVersion, url: URL, asset: GitHubAsset)? {
        var best: (version: AppVersion, url: URL, asset: GitHubAsset)?

        for release in releases where !release.draft {
            guard let url = URL(string: release.htmlURL) else { continue }
            let candidates = [release.tagName, release.name ?? ""]
            guard let version = candidates.compactMap(parseVersion).max() else { continue }
            guard let asset = release.assets.first(where: { $0.name.lowercased().hasSuffix(updateAssetExtension) }),
                  URL(string: asset.browserDownloadURL) != nil else {
                continue
            }

            if let existing = best {
                if version > existing.version {
                    best = (version, url, asset)
                }
            } else {
                best = (version, url, asset)
            }
        }

        return best
    }

    nonisolated private static func parseVersion(_ raw: String) -> AppVersion? {
        let pattern = "\\d+(?:\\.\\d+)+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, options: [], range: range),
              let swiftRange = Range(match.range, in: raw) else {
            return nil
        }
        let text = String(raw[swiftRange])
        let parts = text.split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        return AppVersion(parts: parts)
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let draft: Bool
    let htmlURL: String
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case draft
        case htmlURL = "html_url"
        case assets
    }
}

private struct GitHubAsset: Decodable, Equatable {
    let name: String
    let browserDownloadURL: String
    var url: URL { URL(string: browserDownloadURL)! }

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

private struct AppVersion: Comparable, Sendable {
    let parts: [Int]
    var display: String { parts.map(String.init).joined(separator: ".") }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let maxCount = max(lhs.parts.count, rhs.parts.count)
        for idx in 0..<maxCount {
            let left = idx < lhs.parts.count ? lhs.parts[idx] : 0
            let right = idx < rhs.parts.count ? rhs.parts[idx] : 0
            if left != right { return left < right }
        }
        return false
    }
}
