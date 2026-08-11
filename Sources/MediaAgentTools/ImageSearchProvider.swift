import Foundation

/// One image search candidate. Nothing has been downloaded or checked yet — `save_image_url` does
/// that, and a candidate can still fail validation there.
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

/// Web image search, injected into `MediaToolKit`. Leaving it `nil` removes `search_images` from
/// the toolkit rather than causing a failure later.
public protocol ImageSearchProvider: Sendable {
    /// Searches for images and returns at most `count` candidates; fewer, or none, is a normal result.
    func searchImages(query: String, count: Int) async throws -> [ImageSearchHit]
}

/// One video search candidate. Its existence is unverified until `save_video_reference` resolves it
/// through oEmbed.
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

/// Web video search, injected into `MediaToolKit`. Leaving it `nil` removes `search_videos` from
/// the toolkit rather than causing a failure later.
public protocol VideoSearchProvider: Sendable {
    /// Searches for videos and returns at most `count` candidates, in practice mostly YouTube.
    func searchVideos(query: String, count: Int) async throws -> [VideoSearchHit]
}

// MARK: - Serper

/// Image and video search through Serper (google.serper.dev), covering both provider protocols on
/// one API key.
///
/// Chosen because the alternatives are gone or going: the Bing Search API is retired and Google CSE
/// shuts down in 2027-01.
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
