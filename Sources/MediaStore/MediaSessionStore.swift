import CryptoKit
import Foundation

/// Filesystem failure while creating a session directory or writing a media file.
public enum MediaStoreError: Error, Sendable, LocalizedError {
    /// The session directory could not be created, which leaves the store unusable. Carries the path.
    case directoryCreationFailed(String)
    /// The file could not be written; nothing was appended to the ledger. Carries the path.
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .directoryCreationFailed(let path): "Failed to create media directory at \(path)"
        case .writeFailed(let path): "Failed to write media file at \(path)"
        }
    }
}

/// Media artifacts belonging to one conversation session, held on disk.
///
/// Everything sits flat under `<root>/<sessionID>/`: the media files themselves plus a
/// `manifest.json` ledger, where `<root>` defaults to `Application Support/MediaAgent`. Nothing
/// here expires on its own — the directory outlives the process until
/// `deleteSessionDirectory(sessionID:rootDirectory:)` removes it.
///
/// Reopening the same session ID rebuilds both the ledger and the content-hash index from disk, so
/// saving stays idempotent across launches: name collisions resolve deterministically to `-2`,
/// `-3` suffixes and identical bytes are never written twice.
public actor MediaSessionStore {
    public let sessionID: String
    public let directory: URL

    private var manifest: MediaManifest
    /// SHA-256 of a file's contents to the item already holding those bytes, so a payload is stored once.
    private var contentIndex: [String: MediaItem] = [:]

    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }

    /// Creates the session directory if it is missing and restores any ledger already in it.
    ///
    /// Restoring re-reads every file the ledger names in order to rebuild the deduplication index,
    /// so opening a session costs time proportional to the files it holds. A ledger that fails to
    /// decode is discarded and the session starts empty, while the files it described stay on disk.
    ///
    /// - Parameters:
    ///   - rootDirectory: Base directory holding every session. Defaults to `Application Support/MediaAgent`.
    ///   - sessionID: Identifies the conversation, and names the directory created under `rootDirectory`.
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

    /// Removes a session's directory, media files and ledger together.
    ///
    /// Call this when the conversation itself is deleted; nothing else ever reclaims the files.
    /// Failure is ignored — a missing or undeletable directory is not reported — so a successful
    /// return is not evidence the bytes are gone.
    public static func deleteSessionDirectory(sessionID: String, rootDirectory: URL? = nil) {
        let root = rootDirectory ?? defaultRootDirectory()
        try? FileManager.default.removeItem(at: root.appendingPathComponent(sessionID, isDirectory: true))
    }

    // MARK: - Save

    /// Outcome of a save, including where the bytes ended up.
    ///
    /// `reused == true` means an identical payload was already present: no file was written and
    /// `item` is the pre-existing record, so its `filename` will not reflect the hint just passed in.
    public struct SaveResult: Sendable {
        public let item: MediaItem
        public let fileURL: URL
        public let reused: Bool
    }

    /// Writes bytes into the session directory and appends a record to the ledger.
    ///
    /// - `filenameHint` is slugified to ASCII; a hint with no ASCII alphanumerics becomes `media`,
    ///   and a name already taken gains a `-2`, `-3` … suffix.
    /// - Identical bytes short-circuit on a SHA-256 match: no file is written and the existing
    ///   record comes back with `reused == true`.
    /// - The ledger is rewritten after each save, but a failure to write it is swallowed, so the
    ///   in-memory ledger can run ahead of the one on disk.
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

    /// Every record in save order. A deduplicated payload appears once, at the position of its first save.
    public func allItems() -> [MediaItem] { manifest.items }

    /// Snapshot of the ledger, session ID included.
    ///
    /// Being a value, it will not observe later `save` calls.
    public func currentManifest() -> MediaManifest { manifest }

    /// Where an item's bytes sit right now, obtainable without awaiting the actor.
    ///
    /// Valid only for this run of the process: the path embeds the current app container, which a
    /// reinstall or rebuild replaces. Anything outliving the run — a persisted reference, a URL
    /// handed to an LLM — must use `stableURL(for:)` and resolve it through
    /// `fileURL(forStable:rootDirectory:)` at the moment of use.
    public nonisolated func fileURL(for item: MediaItem) -> URL {
        directory.appendingPathComponent(item.filename)
    }

    // MARK: - Stable references

    /// URL scheme (`media`) for references that survive a change of container path.
    ///
    /// A `file://` path dies the moment the container UUID changes on reinstall or rebuild, so
    /// every reference that gets persisted or handed to an LLM takes the form
    /// `media://<sessionID>/<filename>` and is turned back into a real path by
    /// `fileURL(forStable:rootDirectory:)` at the point of use.
    public static let stableScheme = "media"

    /// Reference of the form `media://<sessionID>/<filename>`, safe to persist or give to an LLM.
    ///
    /// No image loader accepts it directly — resolve it with `fileURL(forStable:rootDirectory:)` first.
    public nonisolated func stableURL(for item: MediaItem) -> URL {
        URL(string: "\(Self.stableScheme)://\(sessionID)/\(item.filename)")!
    }

    /// Turns a `media://` reference back into a path under the current container.
    ///
    /// Parses `absoluteString` by hand instead of reading `host`, because `URL` may lowercase the
    /// host while session IDs are uppercase UUIDs on a case-sensitive data container — the
    /// normalized form would point at a directory that does not exist.
    ///
    /// - Returns: `nil` for anything that is not a well-formed `media://<sessionID>/<filename>`.
    ///   The path is returned without checking that a file is actually there.
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

    /// Reduces a hint to lowercase ASCII alphanumerics joined by dashes, capped at 60 characters.
    ///
    /// Anything with no ASCII alphanumerics — Japanese text, punctuation alone — collapses to
    /// `media`, so unrelated hints can converge on the same name and get `-2`, `-3` suffixes.
    public static func slugify(_ hint: String) -> String {
        let lowered = hint.lowercased()
        var result = ""
        var lastWasDash = true  // starts true so a leading dash is never emitted
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
