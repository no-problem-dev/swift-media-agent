import Foundation

/// What a stored file is, which also determines which of `MediaItem`'s optional fields are filled in.
public enum MediaKind: String, Sendable, Codable, CaseIterable {
    /// Produced by a cloud or on-device image model; carries `prompt`.
    case generatedImage
    /// Downloaded from the web and validated before it reached disk; carries `sourceURL` and `pageURL`.
    case fetchedImage
    /// Rendered from a declarative chart configuration; carries `chartSpec`.
    case chart
    /// Stands in for a video. The video itself is never downloaded — only `videoURL` and `videoTitle` are kept.
    case videoThumbnail
}

/// One media file as recorded in a session's ledger, stored alongside the bytes themselves.
///
/// Deliberately holds `filename` and never an absolute path: on iOS the app container path changes
/// between launches, so a stored absolute URL goes stale. Resolve the location on demand with
/// `MediaSessionStore.fileURL(for:)`, or use `MediaSessionStore.stableURL(for:)` for a reference
/// that can safely be persisted or handed to an LLM.
public struct MediaItem: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let kind: MediaKind
    public let filename: String
    public let mimeType: String
    public let byteCount: Int
    public let width: Int?
    public let height: Int?
    /// Alternative text, serving both accessibility and telling a downstream UI agent what the image shows.
    public let alt: String?
    /// Direct image URL the bytes came from. Set for `fetchedImage`.
    public let sourceURL: String?
    /// Page the image was found on, kept for attribution and reused as the `Referer` when re-fetching.
    public let pageURL: String?
    /// Prompt the image was generated from. Set for `generatedImage`.
    public let prompt: String?
    /// Chart.js configuration the chart was rendered from, retained so it can be redrawn natively later.
    public let chartSpec: String?
    /// Video this thumbnail links to. Set for `videoThumbnail`.
    public let videoURL: String?
    /// Title reported by oEmbed when the reference was saved. Set for `videoThumbnail`.
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

/// Everything saved in one session, persisted as `manifest.json` beside the files
/// and reloaded whenever a store reopens the same session ID.
public struct MediaManifest: Sendable, Codable, Equatable {
    public let sessionID: String
    public var items: [MediaItem]

    public init(sessionID: String, items: [MediaItem] = []) {
        self.sessionID = sessionID
        self.items = items
    }
}
