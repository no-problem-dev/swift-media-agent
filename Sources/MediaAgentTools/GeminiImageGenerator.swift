import Foundation

/// Seam for cloud image generation, substituted with a mock in tests.
public protocol ImageGenerating: Sendable {
    /// Generates images from a prompt and returns their encoded bytes, usually PNG.
    ///
    /// - Parameters:
    ///   - prompt: English prompt naming subject, style and composition. Vague prompts are the
    ///     main source of unusable output.
    ///   - aspectRatio: Ratio such as `"1:1"` or `"16:9"`. `nil` accepts the implementation's default.
    ///   - count: How many images are wanted. An implementation may spend one request per image.
    func generateImages(prompt: String, aspectRatio: String?, count: Int) async throws -> [Data]
}

public enum ImageGeneratorError: Error, Sendable, LocalizedError {
    case emptyResponse
    case invalidBase64

    public var errorDescription: String? {
        switch self {
        case .emptyResponse: "Image generation returned no image"
        case .invalidBase64: "Image generation returned invalid base64 data"
        }
    }
}

/// Image generation over the Gemini `generateContent` endpoint using `responseModalities`.
///
/// - Note: This duplicates ground that belongs to swift-llm-cloud's `GeminiClient+ImageGeneration`.
///   The published `GeminiImageModel` there only reaches models that no longer exist — Imagen 4
///   shut down on 2026-06-24 and `gemini-2.0-flash-exp` is retired — so a self-contained
///   implementation is what keeps current models reachable.
public struct GeminiImageGenerator: ImageGenerating {
    /// Selectable image models, generally available as of 2026-06.
    public enum Preset: String, Codable, Sendable, CaseIterable, Identifiable {
        /// Nano Banana 2. Fast and cheap, and the default.
        case flashImage31 = "gemini-3.1-flash-image"
        /// Nano Banana Pro. Worth the cost when the image must carry legible text, a diagram, or up to 4K.
        case proImage3 = "gemini-3-pro-image"
        /// Previous-generation Nano Banana, scheduled for shutdown in 2026-10.
        case flashImage25 = "gemini-2.5-flash-image"

        public static let `default`: Preset = .flashImage31

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .flashImage31: "Gemini 3.1 Flash Image"
            case .proImage3: "Gemini 3 Pro Image"
            case .flashImage25: "Gemini 2.5 Flash Image"
            }
        }
    }

    public static let defaultModel = Preset.default.rawValue

    public let apiKey: String
    public let model: String
    let http: any MediaHTTPClient
    let baseURL: URL

    public init(
        apiKey: String,
        model: String = GeminiImageGenerator.defaultModel,
        http: (any MediaHTTPClient)? = nil,
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!
    ) {
        self.apiKey = apiKey
        self.model = model
        // Generation can run for tens of seconds, Pro at high resolution especially, so this
        // timeout is far longer than the rest of the package uses.
        self.http = http ?? URLSessionMediaHTTPClient(defaultTimeout: 180)
        self.baseURL = baseURL
    }

    public func generateImages(prompt: String, aspectRatio: String?, count: Int) async throws -> [Data] {
        var images: [Data] = []
        for _ in 0..<max(1, count) {  // Gemini Image returns one image per request
            images.append(contentsOf: try await generateOnce(prompt: prompt, aspectRatio: aspectRatio))
        }
        guard !images.isEmpty else { throw ImageGeneratorError.emptyResponse }
        return images
    }

    private func generateOnce(prompt: String, aspectRatio: String?) async throws -> [Data] {
        do {
            return try await request(prompt: prompt, aspectRatio: aspectRatio)
        } catch let error as MediaHTTPError {
            // The aspect-ratio field has moved between API revisions (imageConfig /
            // responseFormat.image), so a 400 naming an unknown field is retried once without it
            // rather than surfaced as a failure.
            if case .status(400, let body) = error, aspectRatio != nil,
               body.contains("imageConfig") || body.contains("Unknown name") {
                return try await request(prompt: prompt, aspectRatio: nil)
            }
            throw error
        }
    }

    private func request(prompt: String, aspectRatio: String?) async throws -> [Data] {
        let url = baseURL.appendingPathComponent("models/\(model):generateContent")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let body = RequestBody(
            contents: [.init(parts: [.init(text: prompt)])],
            generationConfig: .init(
                responseModalities: ["TEXT", "IMAGE"],
                imageConfig: aspectRatio.map { .init(aspectRatio: $0) }
            )
        )
        urlRequest.httpBody = try JSONEncoder().encode(body)

        let (data, _) = try await http.sendExpectingSuccess(urlRequest)
        let response = try JSONDecoder().decode(ResponseBody.self, from: data)

        var images: [Data] = []
        for candidate in response.candidates ?? [] {
            for part in candidate.content?.parts ?? [] {
                guard let base64 = part.inlineData?.data else { continue }
                guard let imageData = Data(base64Encoded: base64) else {
                    throw ImageGeneratorError.invalidBase64
                }
                images.append(imageData)
            }
        }
        return images
    }

    // MARK: - Wire types

    private struct RequestBody: Encodable {
        let contents: [Content]
        let generationConfig: GenerationConfig
        struct Content: Encodable { let parts: [Part] }
        struct Part: Encodable { let text: String }
        struct GenerationConfig: Encodable {
            let responseModalities: [String]
            let imageConfig: ImageConfig?
        }
        struct ImageConfig: Encodable { let aspectRatio: String }
    }

    private struct ResponseBody: Decodable {
        let candidates: [Candidate]?
        struct Candidate: Decodable { let content: Content? }
        struct Content: Decodable { let parts: [Part]? }
        struct Part: Decodable { let inlineData: InlineData? }
        struct InlineData: Decodable { let mimeType: String?; let data: String? }
    }
}
