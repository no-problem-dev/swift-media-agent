import Foundation
import LLMClient
import LLMTool
import MediaStore

/// visualizer エージェントに渡すメディア準備ツール一式。
///
/// 検証パイプライン（gpt-researcher / ADK ArtifactService の知見を踏襲）:
/// 1. 取得・生成したバイトはマジックバイト + ImageIO 寸法で必ず検証する
/// 2. 検証を通ったバイトはセッションディレクトリへ保存（リホスト）する —
///    リモート URL は hotlink 防止・署名期限切れ・将来の 404 で死ぬため信用しない
/// 3. 同一内容は SHA-256 で重複排除、結果はすべて manifest.json に台帳化する
public struct MediaToolKit: Sendable {
    public let store: MediaSessionStore
    let imageGenerator: (any ImageGenerating)?
    let onDeviceImageGenerator: (any OnDeviceImageGenerating)?
    let imageSearch: (any ImageSearchProvider)?
    let videoSearch: (any VideoSearchProvider)?
    let chartRenderer: any ChartRendering
    let oEmbed: YouTubeOEmbed
    let http: any MediaHTTPClient
    let policy: ImageValidationPolicy
    /// 生成画像・チャートはサイズが保証されるため寸法フィルタを通さない
    let trustedPolicy: ImageValidationPolicy

    public init(
        store: MediaSessionStore,
        imageGenerator: (any ImageGenerating)? = nil,
        onDeviceImageGenerator: (any OnDeviceImageGenerating)? = nil,
        imageSearch: (any ImageSearchProvider)? = nil,
        videoSearch: (any VideoSearchProvider)? = nil,
        chartRenderer: (any ChartRendering)? = nil,
        http: (any MediaHTTPClient)? = nil,
        validationPolicy: ImageValidationPolicy = .default
    ) {
        let httpClient = http ?? URLSessionMediaHTTPClient(defaultTimeout: 30)
        self.store = store
        self.imageGenerator = imageGenerator
        self.onDeviceImageGenerator = onDeviceImageGenerator
        self.imageSearch = imageSearch
        self.videoSearch = videoSearch
        self.chartRenderer = chartRenderer ?? QuickChartRenderer(http: httpClient)
        self.oEmbed = YouTubeOEmbed(http: httpClient)
        self.http = httpClient
        self.policy = validationPolicy
        var trusted = validationPolicy
        trusted.minShortSide = 1
        trusted.maxAspectRatio = 100
        self.trustedPolicy = trusted
    }

    /// Gemini 画像生成 + Serper 検索の標準構成。
    /// `onDeviceImageGenerator` はデバイスが対応する場合のみ渡す —
    /// 非対応なら nil にしてツール自体を編成から外す（実行時失敗はツールがエラーを返す）。
    public static func gemini(
        store: MediaSessionStore,
        geminiAPIKey: String,
        imageModel: String = GeminiImageGenerator.defaultModel,
        serperAPIKey: String? = nil,
        gl: String? = nil,
        hl: String? = nil,
        onDeviceImageGenerator: (any OnDeviceImageGenerating)? = nil
    ) -> MediaToolKit {
        let serper = serperAPIKey
            .flatMap { $0.isEmpty ? nil : SerperMediaSearchProvider(apiKey: $0, gl: gl, hl: hl) }
        return MediaToolKit(
            store: store,
            imageGenerator: GeminiImageGenerator(apiKey: geminiAPIKey, model: imageModel),
            onDeviceImageGenerator: onDeviceImageGenerator,
            imageSearch: serper,
            videoSearch: serper
        )
    }

    /// 構成済みプロバイダすべてが提供するツール一式（全 ID が有効）。
    ///
    /// 特定ツールを除外したい場合は `tools(enabled:)` を使う。
    public var tools: [any Tool] {
        tools(enabled: MediaToolID.allTools)
    }

    /// 構成済みプロバイダから提供可能なツール ID（`tools(enabled:)` の上限）。
    /// ホスト UI はこれで「キー未設定で使えないツール」を判別できる。
    public var availableToolIDs: Set<MediaToolID> {
        var ids = MediaToolID.coreTools
        ids.insert(.createChart) // renderer は常に構成される
        if imageGenerator != nil { ids.insert(.generateImage) }
        if onDeviceImageGenerator != nil { ids.insert(.generateUIImage) }
        if imageSearch != nil { ids.insert(.searchImages) }
        if videoSearch != nil { ids.insert(.searchVideos) }
        return ids
    }

    /// enabled で選別したツール一式。コアツールは常に含まれ、
    /// プロバイダ未構成のツールは enabled に含めても落ちる。
    /// ツール説明内のクロス参照（generate_image ↔ search_images ↔ create_chart）も
    /// 同じセットで剪定されるため、存在しないツールへの誘導が説明文に残らない。
    public func tools(enabled: Set<MediaToolID>) -> [any Tool] {
        let effective = availableToolIDs.intersection(enabled.union(MediaToolID.coreTools))
        var tools: [any Tool] = []
        if effective.contains(.generateImage) { tools.append(generateImageTool(peers: effective)) }
        if effective.contains(.generateUIImage) { tools.append(generateUIImageTool(peers: effective)) }
        if effective.contains(.searchImages) { tools.append(searchImagesTool) }
        tools.append(saveImageURLTool(peers: effective))
        if effective.contains(.searchVideos) { tools.append(searchVideosTool) }
        tools.append(saveVideoReferenceTool)
        if effective.contains(.createChart) { tools.append(createChartTool(peers: effective)) }
        tools.append(listSavedMediaTool)
        return tools
    }

    // MARK: - 共通の保存結果

    struct SavedAsset: Encodable {
        /// 安定参照（`media://<sessionID>/<filename>`）。絶対 file:// パスは
        /// コンテナ UUID 依存でアーカイブ復元後に死ぬため、LLM へは渡さない。
        let mediaUrl: String
        let filename: String
        let kind: String
        let mimeType: String
        let width: Int?
        let height: Int?
        let reused: Bool

        init(_ result: MediaSessionStore.SaveResult, store: MediaSessionStore) {
            mediaUrl = store.stableURL(for: result.item).absoluteString
            filename = result.item.filename
            kind = result.item.kind.rawValue
            mimeType = result.item.mimeType
            width = result.item.width
            height = result.item.height
            reused = result.reused
        }
    }

    // MARK: - generate_image

    private func generateImageTool(peers: Set<MediaToolID>) -> any Tool {
        struct Args: Decodable {
            let prompt: String
            let filenameHint: String
            let aspectRatio: String?
            let altText: String?
        }
        let generator = imageGenerator!
        let store = store
        let policy = trustedPolicy
        // 「代わりにこれを使え」の誘導は同伴するツールにだけ向ける。
        let redirects = [
            peers.contains(.searchImages) ? "search_images" : nil,
            peers.contains(.createChart) ? "create_chart" : nil,
        ].compactMap(\.self)
        let prohibition = redirects.isEmpty
            ? "Do NOT use for real people, products, places, or data charts."
            : "Do NOT use for real people, products, places, or data charts (use \(redirects.joined(separator: " / ")) instead)."
        // オンデバイス生成が同伴する構成では、装飾用途をそちらへ誘導する。
        let decorationSteer = peers.contains(.generateUIImage)
            ? " For purely decorative UI imagery where stylized output is fine, prefer generate_ui_image (free, on-device)."
            : ""
        return MediaTool(
            name: "generate_image",
            description: """
            Generate a high-quality image with a cloud AI image model and save it to the session media directory. \
            Use for concept illustrations, hero/header art, and diagrams without exact numeric data. \
            \(prohibition)\(decorationSteer) \
            Write the prompt in English with concrete style, subject, and composition.
            """,
            inputSchema: .object(
                properties: [
                    "prompt": .string(description: "Detailed English image prompt (subject, style, composition, colors)"),
                    "filename_hint": .string(description: "Short kebab-case base name for the saved file, e.g. 'solar-panel-hero'"),
                    "aspect_ratio": .string(
                        description: "Aspect ratio of the generated image (default 1:1)",
                        enum: ["1:1", "16:9", "9:16", "4:3", "3:4"]
                    ),
                    "alt_text": .string(description: "Short accessibility description of the image content"),
                ],
                required: ["prompt", "filename_hint"]
            )
        ) { data in
            let args = try ToolArgumentsDecoder.decode(Args.self, from: data)
            let images = try await generator.generateImages(
                prompt: args.prompt, aspectRatio: args.aspectRatio, count: 1
            )
            let validated = try ImageDataInspector.validate(images[0], policy: policy)
            let result = try await store.save(
                images[0],
                filenameHint: args.filenameHint,
                fileExtension: validated.format.fileExtension,
                kind: .generatedImage,
                mimeType: validated.format.mimeType,
                width: validated.width,
                height: validated.height,
                alt: args.altText ?? args.prompt,
                prompt: args.prompt
            )
            return try .encodedSnakeCase(SavedAsset(result, store: store))
        }
    }

    // MARK: - generate_ui_image

    private func generateUIImageTool(peers: Set<MediaToolID>) -> any Tool {
        struct Args: Decodable {
            let prompt: String
            let filenameHint: String
            let style: String?
            let altText: String?
        }
        let generator = onDeviceImageGenerator!
        let store = store
        let policy = trustedPolicy
        // 高品質生成が同伴する構成でだけ「忠実度が要るならそちら」の対比を載せる。
        let contrast = peers.contains(.generateImage)
            ? " For high-quality concept art or anything needing fidelity, use generate_image instead."
            : ""
        return MediaTool(
            name: "generate_ui_image",
            description: """
            Generate a decorative image ON-DEVICE with Apple's Image Playground model — free and fast, \
            but stylized only (animation / illustration / sketch). \
            Use for UI decoration where exact fidelity does not matter: ambient backdrops, thumbnails, \
            playful spot illustrations, section accents. \
            It cannot render photorealism, accurate text, real people/products, or precise diagrams.\(contrast) \
            If this tool errors (on-device generation unavailable), report the asset on a `not found:` line — \
            do NOT substitute another generator for it. \
            Write the prompt in English, short and concrete.
            """,
            inputSchema: .object(
                properties: [
                    "prompt": .string(description: "Short English description of the decorative image (subject, mood, colors)"),
                    "filename_hint": .string(description: "Short kebab-case base name for the saved file, e.g. 'ocean-backdrop'"),
                    "style": .string(
                        description: "Image Playground style (default animation)",
                        enum: PlaygroundImageGenerator.styleNames
                    ),
                    "alt_text": .string(description: "Short accessibility description of the image content"),
                ],
                required: ["prompt", "filename_hint"]
            )
        ) { data in
            let args = try ToolArgumentsDecoder.decode(Args.self, from: data)
            let bytes = try await generator.generateImage(
                prompt: args.prompt, style: args.style ?? "animation"
            )
            let validated = try ImageDataInspector.validate(bytes, policy: policy)
            let result = try await store.save(
                bytes,
                filenameHint: args.filenameHint,
                fileExtension: validated.format.fileExtension,
                kind: .generatedImage,
                mimeType: validated.format.mimeType,
                width: validated.width,
                height: validated.height,
                alt: args.altText ?? args.prompt,
                prompt: args.prompt
            )
            return try .encodedSnakeCase(SavedAsset(result, store: store))
        }
    }

    // MARK: - search_images

    private var searchImagesTool: any Tool {
        struct Args: Decodable {
            let query: String
            let count: Int?
        }
        struct Response: Encodable {
            let candidates: [ImageSearchHit]
            let note: String
        }
        let search = imageSearch!
        return MediaTool(
            name: "search_images",
            description: """
            Search the web for images and return candidate URLs with sizes. \
            Use for real-world subjects (people, products, places, screenshots, artworks). \
            Candidates are NOT saved yet — pick the best ones and call save_image_url to validate and store them.
            """,
            inputSchema: .object(
                properties: [
                    "query": .string(description: "Image search query"),
                    "count": .integer(description: "Number of candidates to return (1-10, default 6)", minimum: 1, maximum: 10),
                ],
                required: ["query"]
            )
        ) { data in
            let args = try ToolArgumentsDecoder.decode(Args.self, from: data)
            let hits = try await search.searchImages(query: args.query, count: args.count ?? 6)
            return try .encodedSnakeCase(Response(
                candidates: hits,
                note: "Call save_image_url for each image you want to use. Prefer larger images and authoritative sources."
            ))
        }
    }

    // MARK: - save_image_url

    private func saveImageURLTool(peers: Set<MediaToolID>) -> any Tool {
        struct Args: Decodable {
            let url: String
            let filenameHint: String
            let altText: String?
            let pageUrl: String?
        }
        let store = store
        let http = http
        let policy = policy
        // 検証失敗時のフォールバック先・URL の出どころの言及も同伴ツールに合わせる。
        let failureFallback = peers.contains(.generateImage)
            ? "If validation fails, try another candidate or fall back to generate_image."
            : "If validation fails, try another candidate."
        let urlOrigin = peers.contains(.searchImages)
            ? "Direct image URL (from search_images or a fetched page)"
            : "Direct image URL (from the task input or a fetched page)"
        return MediaTool(
            name: "save_image_url",
            description: """
            Download an image from a URL, validate it (real image bytes, decodable, minimum size, sane aspect ratio), \
            and save it to the session media directory. Returns the stable media URL on success. \
            \(failureFallback)
            """,
            inputSchema: .object(
                properties: [
                    "url": .string(description: urlOrigin),
                    "filename_hint": .string(description: "Short kebab-case base name for the saved file"),
                    "alt_text": .string(description: "Short description of the image content (for accessibility and captions)"),
                    "page_url": .string(description: "URL of the page the image came from (used as Referer and recorded as the source)"),
                ],
                required: ["url", "filename_hint"]
            )
        ) { data in
            let args = try ToolArgumentsDecoder.decode(Args.self, from: data)
            guard let url = URL(string: args.url), url.scheme == "https" || url.scheme == "http" else {
                return .error("Invalid image URL: \(args.url)")
            }
            let (bytes, _) = try await http.sendExpectingSuccess(
                BrowserHeaders.imageRequest(url: url, referer: args.pageUrl)
            )
            let validated = try ImageDataInspector.validate(bytes, policy: policy)
            let result = try await store.save(
                bytes,
                filenameHint: args.filenameHint,
                fileExtension: validated.format.fileExtension,
                kind: .fetchedImage,
                mimeType: validated.format.mimeType,
                width: validated.width,
                height: validated.height,
                alt: args.altText,
                sourceURL: args.url,
                pageURL: args.pageUrl
            )
            return try .encodedSnakeCase(SavedAsset(result, store: store))
        }
    }

    // MARK: - search_videos

    private var searchVideosTool: any Tool {
        struct Args: Decodable {
            let query: String
            let count: Int?
        }
        struct Response: Encodable {
            let candidates: [VideoSearchHit]
            let note: String
        }
        let search = videoSearch!
        return MediaTool(
            name: "search_videos",
            description: """
            Search the web for videos (mostly YouTube) and return candidates. \
            Pick relevant ones and call save_video_reference to verify availability and store a thumbnail.
            """,
            inputSchema: .object(
                properties: [
                    "query": .string(description: "Video search query"),
                    "count": .integer(description: "Number of candidates to return (1-10, default 5)", minimum: 1, maximum: 10),
                ],
                required: ["query"]
            )
        ) { data in
            let args = try ToolArgumentsDecoder.decode(Args.self, from: data)
            let hits = try await search.searchVideos(query: args.query, count: args.count ?? 5)
            return try .encodedSnakeCase(Response(
                candidates: hits,
                note: "Call save_video_reference for videos worth showing in the UI."
            ))
        }
    }

    // MARK: - save_video_reference

    private var saveVideoReferenceTool: any Tool {
        struct Args: Decodable {
            let videoUrl: String
            let filenameHint: String
        }
        struct Response: Encodable {
            let thumbnail: SavedAsset
            let videoUrl: String
            let title: String
            let author: String?
        }
        let store = store
        let oEmbed = oEmbed
        let policy = trustedPolicy
        return MediaTool(
            name: "save_video_reference",
            description: """
            Verify that a YouTube video exists (via oEmbed), download its thumbnail, and save the thumbnail \
            with the video URL and title to the session media directory. \
            The UI shows the thumbnail image and links to the video.
            """,
            inputSchema: .object(
                properties: [
                    "video_url": .string(description: "YouTube video URL (watch / youtu.be / shorts)"),
                    "filename_hint": .string(description: "Short kebab-case base name for the thumbnail file"),
                ],
                required: ["video_url", "filename_hint"]
            )
        ) { data in
            let args = try ToolArgumentsDecoder.decode(Args.self, from: data)
            let info = try await oEmbed.fetchInfo(videoURL: args.videoUrl)
            let bytes = try await oEmbed.fetchThumbnail(videoURL: args.videoUrl, fallbackURL: info.thumbnailURL)
            let validated = try ImageDataInspector.validate(bytes, policy: policy)
            let result = try await store.save(
                bytes,
                filenameHint: args.filenameHint,
                fileExtension: validated.format.fileExtension,
                kind: .videoThumbnail,
                mimeType: validated.format.mimeType,
                width: validated.width,
                height: validated.height,
                alt: info.title,
                videoURL: args.videoUrl,
                videoTitle: info.title
            )
            return try .encodedSnakeCase(Response(
                thumbnail: SavedAsset(result, store: store),
                videoUrl: args.videoUrl,
                title: info.title,
                author: info.authorName
            ))
        }
    }

    // MARK: - create_chart

    private func createChartTool(peers: Set<MediaToolID>) -> any Tool {
        struct Args: Decodable {
            let title: String
            let chartConfig: String
            let filenameHint: String
            let width: Int?
            let height: Int?
        }
        let store = store
        let renderer = chartRenderer
        let policy = trustedPolicy
        // generate_image が同伴しない構成では対比の言及を落とす。
        let usage = peers.contains(.generateImage)
            ? "Use this — never generate_image — whenever exact numeric data must be visualized."
            : "Use this whenever exact numeric data must be visualized."
        return MediaTool(
            name: "create_chart",
            description: """
            Render a data chart from a Chart.js v4 configuration and save it as a PNG. \
            \(usage) \
            Use ONLY numbers that appear in the task input or were gathered during research; never invent values. \
            Keep labels short and include units in the title or axis labels.
            """,
            inputSchema: .object(
                properties: [
                    "title": .string(description: "Human-readable chart title (also used as alt text)"),
                    "chart_config": .string(description: """
                    Chart.js v4 configuration as a JSON string, e.g. \
                    {"type":"bar","data":{"labels":["A","B"],"datasets":[{"label":"Sales","data":[10,20]}]}}
                    """),
                    "filename_hint": .string(description: "Short kebab-case base name for the saved file"),
                    "width": .integer(description: "Chart width in points (default 800)", minimum: 200, maximum: 2000),
                    "height": .integer(description: "Chart height in points (default 450)", minimum: 200, maximum: 2000),
                ],
                required: ["title", "chart_config", "filename_hint"]
            )
        ) { data in
            let args = try ToolArgumentsDecoder.decode(Args.self, from: data)
            let bytes = try await renderer.render(
                chartConfigJSON: args.chartConfig,
                width: args.width ?? 800,
                height: args.height ?? 450
            )
            let validated = try ImageDataInspector.validate(bytes, policy: policy)
            let result = try await store.save(
                bytes,
                filenameHint: args.filenameHint,
                fileExtension: validated.format.fileExtension,
                kind: .chart,
                mimeType: validated.format.mimeType,
                width: validated.width,
                height: validated.height,
                alt: args.title,
                chartSpec: args.chartConfig
            )
            return try .encodedSnakeCase(SavedAsset(result, store: store))
        }
    }

    // MARK: - list_saved_media

    private var listSavedMediaTool: any Tool {
        struct Entry: Encodable {
            let mediaUrl: String
            let kind: String
            let alt: String?
            let width: Int?
            let height: Int?
            let videoUrl: String?
            let videoTitle: String?
        }
        let store = store
        return MediaTool(
            name: "list_saved_media",
            description: """
            List all media saved in this session with their stable media URLs. \
            Call this before writing your final reply to compose the asset manifest.
            """,
            inputSchema: .object(properties: [:])
        ) { _ in
            let items = await store.allItems()
            let entries = items.map { item in
                Entry(
                    mediaUrl: store.stableURL(for: item).absoluteString,
                    kind: item.kind.rawValue,
                    alt: item.alt,
                    width: item.width,
                    height: item.height,
                    videoUrl: item.videoURL,
                    videoTitle: item.videoTitle
                )
            }
            return try .encodedSnakeCase(entries)
        }
    }
}
