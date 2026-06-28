import CryptoKit
import Foundation

/// `MediaSessionStore` の操作が失敗したときにスローされるエラー。
public enum MediaStoreError: Error, Sendable, LocalizedError {
    /// セッションディレクトリの作成に失敗した。パスを添付する。
    case directoryCreationFailed(String)
    /// ファイルの書き込みに失敗した。パスを添付する。
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

    /// `save(_:...)` の戻り値。保存されたアイテム・ファイル URL・重複排除フラグを含む。
    ///
    /// `reused == true` の場合はファイルを書かず既存アイテムを返した（SHA-256 一致）。
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

    /// セッションに保存されたメディアアイテムを保存順に全件返す。
    public func allItems() -> [MediaItem] { manifest.items }

    /// 現在のマニフェストのスナップショットを返す。
    ///
    /// 返値はコピーであり、その後の `save` 呼び出しの影響を受けない。
    public func currentManifest() -> MediaManifest { manifest }

    /// アイテムの絶対 file URL。
    ///
    /// `nonisolated` のため actor のアイソレーションを取らずに呼び出せる。
    /// ただし戻り値はコンテナパスに依存するため、長期保存や LLM への参照渡しには
    /// `stableURL(for:)` を使い、描画直前に `fileURL(forStable:)` で解決すること。
    public nonisolated func fileURL(for item: MediaItem) -> URL {
        directory.appendingPathComponent(item.filename)
    }

    // MARK: - Stable references

    /// コンテナパスに依存しない安定メディア参照のスキーム。
    ///
    /// 絶対 file:// パスはアプリの再インストール・再ビルドでコンテナ UUID が変わると
    /// 死ぬため、LLM へ渡す参照・永続化される参照は `media://<sessionID>/<filename>`
    /// に統一し、描画直前に `fileURL(forStable:)` で現在のコンテナへ解決する。
    public static let stableScheme = "media"

    /// アイテムの安定参照 URL（`media://<sessionID>/<filename>`）。
    public nonisolated func stableURL(for item: MediaItem) -> URL {
        URL(string: "\(Self.stableScheme)://\(sessionID)/\(item.filename)")!
    }

    /// 安定参照 URL を現在のコンテナの file URL へ解決する。
    ///
    /// URL の host getter は大文字小文字を正規化しうるため（sessionID は UUID 大文字、
    /// iOS のデータコンテナはケースセンシティブ）、absoluteString を文字列として解析する。
    public static func fileURL(forStable url: URL, rootDirectory: URL? = nil) -> URL? {
        let prefix = "\(stableScheme)://"
        let string = url.absoluteString
        guard string.hasPrefix(prefix) else { return nil }
        let parts = string.dropFirst(prefix.count).split(separator: "/", maxSplits: 1)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        let root = rootDirectory ?? defaultRootDirectory()
        return root
            .appendingPathComponent(String(parts[0]), isDirectory: true)
            .appendingPathComponent(String(parts[1]))
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
