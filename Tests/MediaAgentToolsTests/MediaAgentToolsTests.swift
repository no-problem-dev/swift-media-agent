import CoreGraphics
import Foundation
import ImageIO
import LLMTool
import Testing
import UniformTypeIdentifiers

@testable import MediaAgent
@testable import MediaAgentTools
@testable import MediaStore

// MARK: - Fixtures

private func makePNG(width: Int, height: Int, seed: CGFloat = 0.5) -> Data {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: seed, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = context.makeImage()!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
        data as CFMutableData, UTType.png.identifier as CFString, 1, nil
    )!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

private func makeStore() throws -> MediaSessionStore {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("media-tools-tests-\(UUID().uuidString)", isDirectory: true)
    return try MediaSessionStore(rootDirectory: root, sessionID: "session")
}

private func args(_ json: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: json)
}

private func jsonObject(_ result: ToolResult) -> [String: Any] {
    guard case .json(let data) = result else { return [:] }
    return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

// MARK: - Mock HTTP

/// ルーティングテーブル式のモック。最初にマッチしたルートの応答を返す。
struct MockHTTPClient: MediaHTTPClient {
    struct Route: Sendable {
        let matches: @Sendable (URLRequest) -> Bool
        let status: Int
        let body: Data
    }

    let routes: [Route]
    let recorder = Recorder()

    actor Recorder {
        var requests: [URLRequest] = []
        func record(_ request: URLRequest) { requests.append(request) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await recorder.record(request)
        guard let route = routes.first(where: { $0.matches(request) }) else {
            throw MediaHTTPError.status(404, bodyPrefix: "no mock route for \(request.url?.absoluteString ?? "?")")
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: route.status, httpVersion: nil, headerFields: nil
        )!
        return (route.body, response)
    }
}

extension MockHTTPClient.Route {
    static func url(containing fragment: String, status: Int = 200, body: Data) -> MockHTTPClient.Route {
        .init(matches: { $0.url?.absoluteString.contains(fragment) == true }, status: status, body: body)
    }
}

// MARK: - GeminiImageGenerator

@Suite struct GeminiImageGeneratorTests {

    private func generateContentBody(imageData: Data) -> Data {
        let json: [String: Any] = [
            "candidates": [
                ["content": ["parts": [
                    ["text": "here is your image"],
                    ["inlineData": ["mimeType": "image/png", "data": imageData.base64EncodedString()]],
                ]]]
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    @Test func decodesInlineImageData() async throws {
        let png = makePNG(width: 1024, height: 1024)
        let http = MockHTTPClient(routes: [
            .url(containing: "\(GeminiImageGenerator.defaultModel):generateContent", body: generateContentBody(imageData: png))
        ])
        let generator = GeminiImageGenerator(apiKey: "k", http: http)

        let images = try await generator.generateImages(prompt: "a cat", aspectRatio: "1:1", count: 1)
        #expect(images == [png])
    }

    @Test func retriesWithoutImageConfigOn400() async throws {
        let png = makePNG(width: 512, height: 512)
        let rejection = Data(#"{"error":{"message":"Unknown name \"imageConfig\""}}"#.utf8)
        let http = MockHTTPClient(routes: [
            MockHTTPClient.Route(
                matches: { request in
                    let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    return body.contains("imageConfig")
                },
                status: 400,
                body: rejection
            ),
            .url(containing: ":generateContent", body: generateContentBody(imageData: png)),
        ])
        let generator = GeminiImageGenerator(apiKey: "k", http: http)

        let images = try await generator.generateImages(prompt: "a cat", aspectRatio: "16:9", count: 1)
        #expect(images == [png])
        #expect(await http.recorder.requests.count == 2)
    }

    @Test func sendsAPIKeyHeader() async throws {
        let png = makePNG(width: 64, height: 64)
        let http = MockHTTPClient(routes: [
            .url(containing: ":generateContent", body: generateContentBody(imageData: png))
        ])
        let generator = GeminiImageGenerator(apiKey: "secret-key", http: http)
        _ = try await generator.generateImages(prompt: "x", aspectRatio: nil, count: 1)

        let request = await http.recorder.requests.first
        #expect(request?.value(forHTTPHeaderField: "x-goog-api-key") == "secret-key")
    }
}

// MARK: - Serper provider

@Suite struct SerperMediaSearchProviderTests {

    @Test func parsesImageResults() async throws {
        let body = Data("""
        {"images": [
          {"title": "Tokyo Tower", "imageUrl": "https://img.example.com/t.jpg",
           "imageWidth": 1200, "imageHeight": 800, "link": "https://example.com/page"},
          {"title": "No size", "imageUrl": "https://img.example.com/n.jpg"}
        ]}
        """.utf8)
        let http = MockHTTPClient(routes: [.url(containing: "google.serper.dev/images", body: body)])
        let provider = SerperMediaSearchProvider(apiKey: "k", gl: "jp", hl: "ja", http: http)

        let hits = try await provider.searchImages(query: "tokyo tower", count: 5)
        #expect(hits.count == 2)
        #expect(hits[0] == ImageSearchHit(
            title: "Tokyo Tower", imageURL: "https://img.example.com/t.jpg",
            pageURL: "https://example.com/page", width: 1200, height: 800
        ))

        let request = await http.recorder.requests.first
        #expect(request?.value(forHTTPHeaderField: "X-API-KEY") == "k")
        let sentBody = try JSONSerialization.jsonObject(with: request!.httpBody!) as! [String: Any]
        #expect(sentBody["gl"] as? String == "jp")
    }

    @Test func parsesVideoResults() async throws {
        let body = Data("""
        {"videos": [
          {"title": "WWDC Talk", "link": "https://www.youtube.com/watch?v=abc123XYZ_-",
           "channel": "Apple", "duration": "12:34"}
        ]}
        """.utf8)
        let http = MockHTTPClient(routes: [.url(containing: "google.serper.dev/videos", body: body)])
        let provider = SerperMediaSearchProvider(apiKey: "k", http: http)

        let hits = try await provider.searchVideos(query: "wwdc", count: 5)
        #expect(hits == [VideoSearchHit(
            title: "WWDC Talk", videoURL: "https://www.youtube.com/watch?v=abc123XYZ_-",
            channel: "Apple", duration: "12:34"
        )])
    }
}

// MARK: - YouTubeOEmbed

@Suite struct YouTubeOEmbedTests {

    @Test func extractsVideoIDs() {
        #expect(YouTubeOEmbed.videoID(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(YouTubeOEmbed.videoID(from: "https://youtu.be/dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(YouTubeOEmbed.videoID(from: "https://www.youtube.com/shorts/abc-_123") == "abc-_123")
        #expect(YouTubeOEmbed.videoID(from: "https://www.youtube.com/embed/xyz") == "xyz")
        #expect(YouTubeOEmbed.videoID(from: "https://example.com/watch?v=zzz") == nil)
    }

    @Test func thumbnailFallsBackFromMaxresToHQ() async throws {
        let png = makePNG(width: 480, height: 360)
        let http = MockHTTPClient(routes: [
            .url(containing: "maxresdefault.jpg", status: 404, body: Data("not found".utf8)),
            .url(containing: "hqdefault.jpg", body: png),
        ])
        let oEmbed = YouTubeOEmbed(http: http)

        let data = try await oEmbed.fetchThumbnail(
            videoURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", fallbackURL: nil
        )
        #expect(data == png)
    }

    @Test func unavailableVideoThrows() async {
        let http = MockHTTPClient(routes: [
            .url(containing: "oembed", status: 404, body: Data("Not Found".utf8))
        ])
        let oEmbed = YouTubeOEmbed(http: http)
        await #expect(throws: YouTubeOEmbedError.self) {
            _ = try await oEmbed.fetchInfo(videoURL: "https://www.youtube.com/watch?v=gone")
        }
    }
}

// MARK: - MediaToolKit tools

@Suite struct MediaToolKitTests {

    private func tool(named name: String, in kit: MediaToolKit) -> any Tool {
        kit.tools.first { $0.toolName == name }!
    }

    @Test func toolCompositionFollowsConfiguration() throws {
        let bare = MediaToolKit(store: try makeStore(), http: MockHTTPClient(routes: []))
        #expect(bare.tools.map(\.toolName) == [
            "save_image_url", "save_video_reference", "create_chart", "list_saved_media",
        ])

        let full = MediaToolKit.gemini(
            store: try makeStore(), geminiAPIKey: "k", serperAPIKey: "s"
        )
        #expect(full.tools.map(\.toolName) == [
            "generate_image", "search_images", "save_image_url",
            "search_videos", "save_video_reference", "create_chart", "list_saved_media",
        ])
    }

    @Test func saveImageURLStoresValidatedImage() async throws {
        let store = try makeStore()
        let png = makePNG(width: 800, height: 600)
        let http = MockHTTPClient(routes: [.url(containing: "example.com/photo.png", body: png)])
        let kit = MediaToolKit(store: store, http: http)

        let result = try await tool(named: "save_image_url", in: kit).execute(with: args([
            "url": "https://example.com/photo.png",
            "filename_hint": "skyline",
            "alt_text": "City skyline",
            "page_url": "https://example.com/article",
        ]))

        let payload = jsonObject(result)
        #expect(payload["filename"] as? String == "skyline.png")
        #expect((payload["file_url"] as? String)?.hasPrefix("file://") == true)
        #expect(payload["width"] as? Int == 800)

        let items = await store.allItems()
        #expect(items.count == 1)
        #expect(items[0].kind == .fetchedImage)
        #expect(items[0].pageURL == "https://example.com/article")

        // hotlink 対策ヘッダが付いていること
        let request = await http.recorder.requests.first
        #expect(request?.value(forHTTPHeaderField: "Referer") == "https://example.com/article")
        #expect(request?.value(forHTTPHeaderField: "User-Agent")?.contains("Mozilla") == true)
    }

    @Test func saveImageURLRejectsHTMLBody() async throws {
        let store = try makeStore()
        let http = MockHTTPClient(routes: [
            .url(containing: "example.com", body: Data("<html><body>blocked</body></html>".utf8))
        ])
        let kit = MediaToolKit(store: store, http: http)

        let result = try await tool(named: "save_image_url", in: kit).execute(with: args([
            "url": "https://example.com/photo.png", "filename_hint": "x",
        ]))

        #expect(result.isError)
        #expect(result.stringValue.contains("not an image"))
        #expect(await store.allItems().isEmpty)
    }

    @Test func saveImageURLRejectsTinyImage() async throws {
        let store = try makeStore()
        let http = MockHTTPClient(routes: [
            .url(containing: "example.com", body: makePNG(width: 32, height: 32))
        ])
        let kit = MediaToolKit(store: store, http: http)

        let result = try await tool(named: "save_image_url", in: kit).execute(with: args([
            "url": "https://example.com/icon.png", "filename_hint": "icon",
        ]))

        #expect(result.isError)
        #expect(result.stringValue.contains("too small"))
    }

    @Test func generateImageStoresResult() async throws {
        struct StubGenerator: ImageGenerating {
            let data: Data
            func generateImages(prompt: String, aspectRatio: String?, count: Int) async throws -> [Data] {
                [data]
            }
        }
        let store = try makeStore()
        let kit = MediaToolKit(
            store: store,
            imageGenerator: StubGenerator(data: makePNG(width: 1024, height: 1024)),
            http: MockHTTPClient(routes: [])
        )

        let result = try await tool(named: "generate_image", in: kit).execute(with: args([
            "prompt": "flat illustration of solar panels",
            "filename_hint": "solar-hero",
            "aspect_ratio": "16:9",
        ]))

        let payload = jsonObject(result)
        #expect(payload["kind"] as? String == "generatedImage")
        let items = await store.allItems()
        #expect(items[0].prompt == "flat illustration of solar panels")
    }

    @Test func createChartValidatesConfigAndKeepsSpec() async throws {
        let store = try makeStore()
        let chartPNG = makePNG(width: 800, height: 450)
        let http = MockHTTPClient(routes: [.url(containing: "quickchart.io/chart", body: chartPNG)])
        let kit = MediaToolKit(store: store, http: http)
        let chartTool = tool(named: "create_chart", in: kit)

        // 不正な JSON は弾く
        let invalid = try await chartTool.execute(with: args([
            "title": "Bad", "chart_config": "{not json", "filename_hint": "bad",
        ]))
        #expect(invalid.isError)

        // 正常系: 保存され chartSpec が台帳に残る
        let config = #"{"type":"bar","data":{"labels":["A","B"],"datasets":[{"label":"v","data":[1,2]}]}}"#
        let result = try await chartTool.execute(with: args([
            "title": "Sales by region", "chart_config": config, "filename_hint": "sales-chart",
        ]))
        let payload = jsonObject(result)
        #expect(payload["kind"] as? String == "chart")

        let items = await store.allItems()
        #expect(items.count == 1)
        #expect(items[0].chartSpec == config)
        #expect(items[0].alt == "Sales by region")
    }

    @Test func saveVideoReferenceVerifiesAndStoresThumbnail() async throws {
        let store = try makeStore()
        let thumbnail = makePNG(width: 480, height: 360)
        let oEmbedBody = Data("""
        {"title": "Great Talk", "author_name": "Some Channel",
         "thumbnail_url": "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"}
        """.utf8)
        let http = MockHTTPClient(routes: [
            .url(containing: "oembed", body: oEmbedBody),
            .url(containing: "maxresdefault.jpg", status: 404, body: Data()),
            .url(containing: "hqdefault.jpg", body: thumbnail),
        ])
        let kit = MediaToolKit(store: store, http: http)

        let result = try await tool(named: "save_video_reference", in: kit).execute(with: args([
            "video_url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "filename_hint": "great-talk",
        ]))

        let payload = jsonObject(result)
        #expect(payload["title"] as? String == "Great Talk")
        let items = await store.allItems()
        #expect(items[0].kind == .videoThumbnail)
        #expect(items[0].videoURL == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(items[0].videoTitle == "Great Talk")
    }

    @Test func listSavedMediaReturnsManifestEntries() async throws {
        let store = try makeStore()
        _ = try await store.save(
            makePNG(width: 400, height: 300), filenameHint: "a", fileExtension: "png",
            kind: .fetchedImage, mimeType: "image/png", alt: "A"
        )
        let kit = MediaToolKit(store: store, http: MockHTTPClient(routes: []))

        let result = try await tool(named: "list_saved_media", in: kit).execute(with: args([:]))
        guard case .json(let data) = result,
              let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            Issue.record("Expected JSON array result")
            return
        }
        #expect(entries.count == 1)
        #expect(entries[0]["alt"] as? String == "A")
        #expect((entries[0]["file_url"] as? String)?.hasSuffix("a.png") == true)
    }
}

// MARK: - VisualizerAgent assembly

@Suite struct VisualizerAgentTests {

    @Test func agentCardDescribesSkills() {
        let card = VisualizerAgent.agentCard(interfaceURL: "inprocess://visualizer")
        #expect(card.name == "visualizer")
        #expect(card.skills.map(\.id) == ["generate-image", "fetch-images", "video-references", "charts"])
        #expect(card.capabilities.streaming == true)
    }

    @Test func toolSetWrapsToolKit() throws {
        let kit = MediaToolKit.gemini(store: try makeStore(), geminiAPIKey: "k", serperAPIKey: "s")
        let toolSet = VisualizerAgent.toolSet(kit)
        #expect(toolSet.count == 7)
    }
}
