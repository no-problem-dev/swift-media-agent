import Foundation

/// 画像生成のシーム。テストではモックに差し替える。
public protocol ImageGenerating: Sendable {
    /// プロンプトから画像を生成し、画像バイト列（通常 PNG）の配列を返す。
    ///
    /// - Parameters:
    ///   - prompt: 英語の画像プロンプト（被写体・スタイル・構図を具体的に記述）
    ///   - aspectRatio: アスペクト比（`"1:1"`, `"16:9"` 等）。`nil` で実装依存のデフォルト
    ///   - count: 生成枚数
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

/// Gemini API（generateContent + responseModalities）による画像生成。
///
/// NOTE: 本来は swift-llm-cloud の `GeminiClient+ImageGeneration` の責務だが、
/// 公開版の `GeminiImageModel` が旧世代（Imagen 4 は 2026-06-24 シャットダウン、
/// gemini-2.0-flash-exp は廃止済み）のみのため、現行モデルを使う最小実装を
/// 自己完結で持つ。upstream のモデルカタログ更新後に差し替える。
public struct GeminiImageGenerator: ImageGenerating {
    /// 選択可能な画像生成モデルのカタログ（2026-06 時点の GA モデル）。
    public enum Preset: String, Codable, Sendable, CaseIterable, Identifiable {
        /// Nano Banana 2。高速・低コストの標準モデル
        case flashImage31 = "gemini-3.1-flash-image"
        /// Nano Banana Pro。テキスト描画・図解・高解像度（〜4K）向き
        case proImage3 = "gemini-3-pro-image"
        /// 旧世代 Nano Banana（2026-10 シャットダウン予定）
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
        // 画像生成は数十秒かかりうる（特に Pro/高解像度）ためタイムアウトを長めに取る
        self.http = http ?? URLSessionMediaHTTPClient(defaultTimeout: 180)
        self.baseURL = baseURL
    }

    public func generateImages(prompt: String, aspectRatio: String?, count: Int) async throws -> [Data] {
        var images: [Data] = []
        for _ in 0..<max(1, count) {  // Gemini Image は 1 リクエスト 1 枚
            images.append(contentsOf: try await generateOnce(prompt: prompt, aspectRatio: aspectRatio))
        }
        guard !images.isEmpty else { throw ImageGeneratorError.emptyResponse }
        return images
    }

    private func generateOnce(prompt: String, aspectRatio: String?) async throws -> [Data] {
        do {
            return try await request(prompt: prompt, aspectRatio: aspectRatio)
        } catch let error as MediaHTTPError {
            // imageConfig はリビジョン間でフィールド名が揺れている（imageConfig / responseFormat.image）。
            // 未知フィールドの 400 はアスペクト指定なしで 1 回だけリトライする。
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
