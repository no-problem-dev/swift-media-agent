import Foundation

/// 画像検索の 1 候補。保存はまだしていない（save_image_url で検証 + 保存する）。
public struct ImageSearchHit: Sendable, Codable, Equatable {
    public let title: String
    public let imageURL: String
    public let pageURL: String?
    public let width: Int?
    public let height: Int?

    public init(title: String, imageURL: String, pageURL: String?, width: Int?, height: Int?) {
        self.title = title
        self.imageURL = imageURL
        self.pageURL = pageURL
        self.width = width
        self.height = height
    }
}

/// Web 画像検索の抽象。`MediaToolKit` に注入してテストでモックに差し替える。
public protocol ImageSearchProvider: Sendable {
    /// クエリで画像を検索し、最大 `count` 件の候補を返す。
    func searchImages(query: String, count: Int) async throws -> [ImageSearchHit]
}

/// 動画検索の 1 候補。
public struct VideoSearchHit: Sendable, Codable, Equatable {
    public let title: String
    public let videoURL: String
    public let channel: String?
    public let duration: String?

    public init(title: String, videoURL: String, channel: String?, duration: String?) {
        self.title = title
        self.videoURL = videoURL
        self.channel = channel
        self.duration = duration
    }
}

/// Web 動画検索の抽象。`MediaToolKit` に注入してテストでモックに差し替える。
public protocol VideoSearchProvider: Sendable {
    /// クエリで動画を検索し、最大 `count` 件の候補を返す。
    func searchVideos(query: String, count: Int) async throws -> [VideoSearchHit]
}

// MARK: - Serper

/// Serper (google.serper.dev) の画像・動画検索。
/// デモが既に Serper キーを持つため第一候補（Bing API は廃止、Google CSE は 2027-01 廃止予定）。
public struct SerperMediaSearchProvider: ImageSearchProvider, VideoSearchProvider {
    public let apiKey: String
    public let gl: String?
    public let hl: String?
    let http: any MediaHTTPClient
    let baseURL: URL

    public init(
        apiKey: String,
        gl: String? = nil,
        hl: String? = nil,
        http: any MediaHTTPClient = URLSessionMediaHTTPClient(defaultTimeout: 20),
        baseURL: URL = URL(string: "https://google.serper.dev")!
    ) {
        self.apiKey = apiKey
        self.gl = gl
        self.hl = hl
        self.http = http
        self.baseURL = baseURL
    }

    public func searchImages(query: String, count: Int) async throws -> [ImageSearchHit] {
        let data = try await post(path: "images", query: query, count: count)
        let response = try JSONDecoder().decode(ImagesResponse.self, from: data)
        return (response.images ?? []).prefix(count).map { image in
            ImageSearchHit(
                title: image.title ?? "",
                imageURL: image.imageUrl,
                pageURL: image.link,
                width: image.imageWidth,
                height: image.imageHeight
            )
        }
    }

    public func searchVideos(query: String, count: Int) async throws -> [VideoSearchHit] {
        let data = try await post(path: "videos", query: query, count: count)
        let response = try JSONDecoder().decode(VideosResponse.self, from: data)
        return (response.videos ?? []).prefix(count).map { video in
            VideoSearchHit(
                title: video.title ?? "",
                videoURL: video.link,
                channel: video.channel,
                duration: video.duration
            )
        }
    }

    private func post(path: String, query: String, count: Int) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-KEY")
        var body: [String: Any] = ["q": query, "num": max(1, min(count, 20))]
        if let gl { body["gl"] = gl }
        if let hl { body["hl"] = hl }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await http.sendExpectingSuccess(request)
        return data
    }

    // MARK: - Wire types

    private struct ImagesResponse: Decodable {
        let images: [Image]?
        struct Image: Decodable {
            let title: String?
            let imageUrl: String
            let imageWidth: Int?
            let imageHeight: Int?
            let link: String?
        }
    }

    private struct VideosResponse: Decodable {
        let videos: [Video]?
        struct Video: Decodable {
            let title: String?
            let link: String
            let channel: String?
            let duration: String?
        }
    }
}
