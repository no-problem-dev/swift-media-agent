import Foundation

/// oEmbed で取得した動画メタデータ。oEmbed の成功自体が動画の存在検証を兼ねる（404 = 削除済み）。
public struct VideoEmbedInfo: Sendable, Equatable {
    public let title: String
    public let authorName: String?
    public let thumbnailURL: String?
}

public enum YouTubeOEmbedError: Error, Sendable, LocalizedError {
    case notAYouTubeURL(String)
    case videoUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .notAYouTubeURL(let url): "Not a recognizable YouTube URL: \(url)"
        case .videoUnavailable(let url): "Video is unavailable or removed: \(url)"
        }
    }
}

/// YouTube の oEmbed 照会とサムネイル URL の導出。API キー不要。
public struct YouTubeOEmbed: Sendable {
    let http: any MediaHTTPClient

    public init(http: any MediaHTTPClient = URLSessionMediaHTTPClient(defaultTimeout: 20)) {
        self.http = http
    }

    /// watch?v= / youtu.be/ / shorts/ / embed/ 形式から動画 ID を抽出する。
    public static func videoID(from urlString: String) -> String? {
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else { return nil }
        let id: String?
        if host.contains("youtu.be") {
            id = url.pathComponents.dropFirst().first
        } else if host.contains("youtube.com") {
            let path = url.pathComponents.dropFirst()
            if let first = path.first, ["shorts", "embed", "v", "live"].contains(first) {
                id = path.dropFirst().first
            } else {
                id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "v" })?.value
            }
        } else {
            id = nil
        }
        guard let id, !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { return nil }
        return id
    }

    /// 動画の存在を検証してメタデータを返す。
    public func fetchInfo(videoURL: String) async throws -> VideoEmbedInfo {
        guard Self.videoID(from: videoURL) != nil else {
            throw YouTubeOEmbedError.notAYouTubeURL(videoURL)
        }
        var components = URLComponents(string: "https://www.youtube.com/oembed")!
        components.queryItems = [
            URLQueryItem(name: "url", value: videoURL),
            URLQueryItem(name: "format", value: "json"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(BrowserHeaders.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await http.send(request)
        guard response.statusCode == 200 else {
            throw YouTubeOEmbedError.videoUnavailable(videoURL)
        }
        let body = try JSONDecoder().decode(OEmbedBody.self, from: data)
        return VideoEmbedInfo(title: body.title ?? "", authorName: body.author_name, thumbnailURL: body.thumbnail_url)
    }

    /// サムネイルを取得する。maxresdefault は存在しない動画が多いので hqdefault（必ず存在）へフォールバック。
    public func fetchThumbnail(videoURL: String, fallbackURL: String?) async throws -> Data {
        var candidates: [String] = []
        if let id = Self.videoID(from: videoURL) {
            candidates.append("https://img.youtube.com/vi/\(id)/maxresdefault.jpg")
            candidates.append("https://img.youtube.com/vi/\(id)/hqdefault.jpg")
        }
        if let fallbackURL { candidates.append(fallbackURL) }

        var lastError: Error = YouTubeOEmbedError.videoUnavailable(videoURL)
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            do {
                let (data, _) = try await http.sendExpectingSuccess(
                    BrowserHeaders.imageRequest(url: url, referer: nil)
                )
                return data
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private struct OEmbedBody: Decodable {
        let title: String?
        let author_name: String?
        let thumbnail_url: String?
    }
}
