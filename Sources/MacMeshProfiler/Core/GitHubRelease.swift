import CryptoKit
import Foundation

struct ReleaseAsset {
    let name: String
    let url: URL
    let size: Int
    /// Hex sha256 published by GitHub for the asset, if available.
    let sha256: String?
}

struct Release {
    let tag: String
    let assets: [ReleaseAsset]

    /// "v0.7.10" → "0.7.10"
    var version: String { tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }
}

enum GitHubError: LocalizedError {
    case http(Int)
    case noAsset(String)
    case checksumMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .http(let code): return "GitHub returned HTTP \(code)."
        case .noAsset(let what): return "The latest release has no \(what) asset."
        case .checksumMismatch(let e, let a): return "Download checksum mismatch (expected \(e), got \(a))."
        }
    }
}

enum GitHub {
    static func latestRelease(repo: String) async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MacMeshProfiler", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw GitHubError.http(http.statusCode)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let tag = json["tag_name"] as? String ?? "?"
        let assets = (json["assets"] as? [[String: Any]] ?? []).compactMap { a -> ReleaseAsset? in
            guard let name = a["name"] as? String,
                  let urlString = a["browser_download_url"] as? String,
                  let url = URL(string: urlString) else { return nil }
            var sha: String?
            if let digest = a["digest"] as? String, digest.hasPrefix("sha256:") {
                sha = String(digest.dropFirst("sha256:".count))
            }
            return ReleaseAsset(name: name, url: url, size: a["size"] as? Int ?? 0, sha256: sha)
        }
        return Release(tag: tag, assets: assets)
    }

    /// Downloads an asset into a fresh private temp directory and verifies its sha256.
    /// Returns the local file and the sha256 that was actually computed.
    static func download(_ asset: ReleaseAsset) async throws -> (file: URL, sha256: String) {
        let (tmp, response) = try await URLSession.shared.download(from: asset.url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw GitHubError.http(http.statusCode)
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacMeshProfiler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let dest = dir.appendingPathComponent(asset.name)
        try FileManager.default.moveItem(at: tmp, to: dest)

        let data = try Data(contentsOf: dest)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let expected = asset.sha256, expected.lowercased() != actual {
            throw GitHubError.checksumMismatch(expected: expected, actual: actual)
        }
        return (dest, actual)
    }

    static var archToken: (rust: String, go: String) {
        #if arch(arm64)
        return ("aarch64", "arm64")
        #else
        return ("x86_64", "amd64")
        #endif
    }
}

/// Compares dotted versions numerically ("0.5.9" < "0.5.13").
func isNewer(_ candidate: String, than current: String) -> Bool {
    let a = candidate.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    let b = current.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0
        let y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}
