import Foundation

/// 保存されたメディアの種別。
public enum MediaKind: String, Sendable, Codable, CaseIterable {
    /// AI が生成した画像
    case generatedImage
    /// Web から取得・検証した画像
    case fetchedImage
    /// データ駆動でレンダリングしたチャート画像
    case chart
    /// 動画参照のサムネイル画像（動画本体は保存しない）
    case videoThumbnail
}

/// セッションディレクトリに保存された 1 メディアのレコード。
///
/// ファイル本体とは別に manifest.json に永続化される。iOS ではアプリコンテナの
/// 絶対パスが起動ごとに変わりうるため、レコードは `filename` のみを持ち、
/// 絶対 URL は `MediaSessionStore.fileURL(for:)` で都度解決する。
public struct MediaItem: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let kind: MediaKind
    public let filename: String
    public let mimeType: String
    public let byteCount: Int
    public let width: Int?
    public let height: Int?
    /// 代替テキスト（アクセシビリティ + UI エージェントへの内容説明）
    public let alt: String?
    /// 取得元の画像 URL（fetchedImage）
    public let sourceURL: String?
    /// 取得元のページ URL（出典表示・再取得用）
    public let pageURL: String?
    /// 生成プロンプト（generatedImage）
    public let prompt: String?
    /// チャートの宣言仕様（Chart.js config JSON）。将来のネイティブ描画用に保持
    public let chartSpec: String?
    /// 参照先の動画 URL（videoThumbnail）
    public let videoURL: String?
    /// 動画タイトル（videoThumbnail）
    public let videoTitle: String?
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        kind: MediaKind,
        filename: String,
        mimeType: String,
        byteCount: Int,
        width: Int? = nil,
        height: Int? = nil,
        alt: String? = nil,
        sourceURL: String? = nil,
        pageURL: String? = nil,
        prompt: String? = nil,
        chartSpec: String? = nil,
        videoURL: String? = nil,
        videoTitle: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.filename = filename
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.width = width
        self.height = height
        self.alt = alt
        self.sourceURL = sourceURL
        self.pageURL = pageURL
        self.prompt = prompt
        self.chartSpec = chartSpec
        self.videoURL = videoURL
        self.videoTitle = videoTitle
        self.createdAt = createdAt
    }
}

/// 1 セッション分のメディア成果物の台帳。
public struct MediaManifest: Sendable, Codable, Equatable {
    public let sessionID: String
    public var items: [MediaItem]

    public init(sessionID: String, items: [MediaItem] = []) {
        self.sessionID = sessionID
        self.items = items
    }
}
