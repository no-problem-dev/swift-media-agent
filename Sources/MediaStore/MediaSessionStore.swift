import CryptoKit
import Foundation

public enum MediaStoreError: Error, Sendable, LocalizedError {
    case directoryCreationFailed(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .directoryCreationFailed(let path): "Failed to create media directory at \(path)"
        case .writeFailed(let path): "Failed to write media file at \(path)"
        }
    }
}

/// 会話セッション単位のメディア成果物ストア。
///
/// `<root>/<sessionID>/` 配下にメディアファイルと manifest.json を保持する。
/// 設計は Google ADK の ArtifactService を踏襲: セッションスコープの名前空間、
/// 決定論的な命名 + 同名衝突時のバージョン付与、内容ハッシュによる重複排除。
/// 再起動後も manifest.json から状態を復元するためべき等。
public actor MediaSessionStore {
    public let sessionID: String
    public let directory: URL

    private var manifest: MediaManifest
    /// SHA-256(内容) → 既存アイテム。同一バイトの二重保存を防ぐ
    private var contentIndex: [String: MediaItem] = [:]

    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }

    /// - Parameters:
    ///   - rootDirectory: ストアのルート。省略時は Application Support/MediaAgent
    ///   - sessionID: 会話セッションの識別子
    public init(rootDirectory: URL? = nil, sessionID: String) throws {
        let root = rootDirectory ?? Self.defaultRootDirectory()
        self.sessionID = sessionID
        self.directory = root.appendingPathComponent(sessionID, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw MediaStoreError.directoryCreationFailed(directory.path)
        }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
           let restored = try? Self.decoder.decode(MediaManifest.self, from: data) {
            self.manifest = restored
        } else {
            self.manifest = MediaManifest(sessionID: sessionID)
        }
        for item in manifest.items {
            let url = directory.appendingPathComponent(item.filename)
            if let data = try? Data(contentsOf: url) {
                contentIndex[Self.hash(data)] = item
            }
        }
    }

    public static func defaultRootDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MediaAgent", isDirectory: true)
    }

    /// セッションディレクトリ（メディアファイル + manifest.json）を丸ごと削除する。
    /// セッション自体の削除に追従させ、孤立ファイルを残さないための API。
    public static func deleteSessionDirectory(sessionID: String, rootDirectory: URL? = nil) {
        let root = rootDirectory ?? defaultRootDirectory()
        try? FileManager.default.removeItem(at: root.appendingPathComponent(sessionID, isDirectory: true))
    }

    // MARK: - Save

    /// 保存結果。`reused` は同一内容が既に保存済みで再利用されたことを示す。
    public struct SaveResult: Sendable {
        public let item: MediaItem
        public let fileURL: URL
        public let reused: Bool
    }

    /// バイト列をセッションディレクトリへ保存し、manifest を更新する。
    ///
    /// - `filenameHint` はスラグ化され、同名がある場合は `-2`, `-3` ... を付与
    /// - 同一内容（SHA-256 一致）が既にあればファイルを書かず既存アイテムを返す
    public func save(
        _ data: Data,
        filenameHint: String,
        fileExtension: String,
        kind: MediaKind,
        mimeType: String,
        width: Int? = nil,
        height: Int? = nil,
        alt: String? = nil,
        sourceURL: String? = nil,
        pageURL: String? = nil,
        prompt: String? = nil,
        chartSpec: String? = nil,
        videoURL: String? = nil,
        videoTitle: String? = nil
    ) throws -> SaveResult {
        let digest = Self.hash(data)
        if let existing = contentIndex[digest] {
            return SaveResult(item: existing, fileURL: fileURL(for: existing), reused: true)
        }

        let filename = uniqueFilename(hint: filenameHint, fileExtension: fileExtension)
        let url = directory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw MediaStoreError.writeFailed(url.path)
        }

        let item = MediaItem(
            kind: kind,
            filename: filename,
            mimeType: mimeType,
            byteCount: data.count,
            width: width,
            height: height,
            alt: alt,
            sourceURL: sourceURL,
            pageURL: pageURL,
            prompt: prompt,
            chartSpec: chartSpec,
            videoURL: videoURL,
            videoTitle: videoTitle
        )
        manifest.items.append(item)
        contentIndex[digest] = item
        persistManifest()
        return SaveResult(item: item, fileURL: url, reused: false)
    }

    // MARK: - Read

    public func allItems() -> [MediaItem] { manifest.items }

    public func currentManifest() -> MediaManifest { manifest }

    public nonisolated func fileURL(for item: MediaItem) -> URL {
        directory.appendingPathComponent(item.filename)
    }

    // MARK: - Naming

    /// ヒントを URL/ファイルシステム安全なスラグへ変換する。
    public static func slugify(_ hint: String) -> String {
        let lowered = hint.lowercased()
        var result = ""
        var lastWasDash = true  // 先頭のダッシュを抑止
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        if result.isEmpty { result = "media" }
        return String(result.prefix(60))
    }

    private func uniqueFilename(hint: String, fileExtension: String) -> String {
        let slug = Self.slugify(hint)
        let existing = Set(manifest.items.map(\.filename))
        var candidate = "\(slug).\(fileExtension)"
        var counter = 2
        while existing.contains(candidate) {
            candidate = "\(slug)-\(counter).\(fileExtension)"
            counter += 1
        }
        return candidate
    }

    // MARK: - Persistence

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func persistManifest() {
        guard let data = try? Self.encoder.encode(manifest) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
