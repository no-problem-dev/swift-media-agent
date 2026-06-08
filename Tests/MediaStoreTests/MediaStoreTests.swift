import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import MediaStore

// MARK: - Fixtures

func makePNG(width: Int, height: Int, seed: CGFloat = 0.5) -> Data {
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

func makeTempRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("media-store-tests-\(UUID().uuidString)", isDirectory: true)
}

// MARK: - ImageDataInspector

@Suite struct ImageDataInspectorTests {

    @Test func sniffsPNG() {
        #expect(ImageDataInspector.sniffFormat(makePNG(width: 10, height: 10)) == .png)
    }

    @Test func sniffsJPEGMagicBytes() {
        var data = Data([0xFF, 0xD8, 0xFF, 0xE0])
        data.append(Data(repeating: 0, count: 16))
        #expect(ImageDataInspector.sniffFormat(data) == .jpeg)
    }

    @Test func rejectsHTMLBody() {
        let html = Data("<html><body>404 Not Found</body></html>".utf8)
        #expect(throws: ImageValidationError.self) {
            try ImageDataInspector.validate(html)
        }
    }

    @Test func readsDimensions() {
        let dims = ImageDataInspector.dimensions(of: makePNG(width: 320, height: 240))
        #expect(dims?.width == 320)
        #expect(dims?.height == 240)
    }

    @Test func acceptsValidImage() throws {
        let validated = try ImageDataInspector.validate(makePNG(width: 400, height: 300))
        #expect(validated == ValidatedImage(format: .png, width: 400, height: 300))
    }

    @Test func rejectsTooSmallImage() {
        #expect(throws: ImageValidationError.tooSmall(width: 100, height: 100, minShortSide: 200)) {
            try ImageDataInspector.validate(makePNG(width: 100, height: 100))
        }
    }

    @Test func rejectsExtremeAspectRatio() {
        // 短辺 200 は満たすが 8:1 のバナー形状
        #expect(throws: ImageValidationError.extremeAspectRatio(width: 1600, height: 200, maxRatio: 4.0)) {
            try ImageDataInspector.validate(makePNG(width: 1600, height: 200))
        }
    }

    @Test func policyIsConfigurable() throws {
        var policy = ImageValidationPolicy()
        policy.minShortSide = 10
        let validated = try ImageDataInspector.validate(makePNG(width: 64, height: 64), policy: policy)
        #expect(validated.width == 64)
    }
}

// MARK: - MediaSessionStore

@Suite struct MediaSessionStoreTests {

    @Test func savesFileAndManifest() async throws {
        let root = makeTempRoot()
        let store = try MediaSessionStore(rootDirectory: root, sessionID: "s1")
        let png = makePNG(width: 400, height: 300)

        let result = try await store.save(
            png, filenameHint: "Tokyo Tower View!", fileExtension: "png",
            kind: .fetchedImage, mimeType: "image/png",
            width: 400, height: 300, alt: "Tokyo Tower",
            sourceURL: "https://example.com/a.png", pageURL: "https://example.com/page"
        )

        #expect(result.item.filename == "tokyo-tower-view.png")
        #expect(result.reused == false)
        #expect(FileManager.default.fileExists(atPath: result.fileURL.path))

        let manifestData = try Data(contentsOf: root.appendingPathComponent("s1/manifest.json"))
        let manifest = try JSONDecoder.withISO8601.decode(MediaManifest.self, from: manifestData)
        #expect(manifest.sessionID == "s1")
        #expect(manifest.items.count == 1)
        #expect(manifest.items[0].sourceURL == "https://example.com/a.png")
    }

    @Test func deduplicatesIdenticalBytes() async throws {
        let store = try MediaSessionStore(rootDirectory: makeTempRoot(), sessionID: "s1")
        let png = makePNG(width: 400, height: 300)

        let first = try await store.save(
            png, filenameHint: "a", fileExtension: "png", kind: .fetchedImage, mimeType: "image/png"
        )
        let second = try await store.save(
            png, filenameHint: "b", fileExtension: "png", kind: .fetchedImage, mimeType: "image/png"
        )

        #expect(second.reused == true)
        #expect(second.item.filename == first.item.filename)
        #expect(await store.allItems().count == 1)
    }

    @Test func versionsFilenameCollisions() async throws {
        let store = try MediaSessionStore(rootDirectory: makeTempRoot(), sessionID: "s1")

        let first = try await store.save(
            makePNG(width: 400, height: 300, seed: 0.1), filenameHint: "chart",
            fileExtension: "png", kind: .chart, mimeType: "image/png"
        )
        let second = try await store.save(
            makePNG(width: 400, height: 300, seed: 0.9), filenameHint: "chart",
            fileExtension: "png", kind: .chart, mimeType: "image/png"
        )

        #expect(first.item.filename == "chart.png")
        #expect(second.item.filename == "chart-2.png")
    }

    @Test func restoresManifestAcrossInstances() async throws {
        let root = makeTempRoot()
        let store = try MediaSessionStore(rootDirectory: root, sessionID: "s1")
        let png = makePNG(width: 400, height: 300)
        _ = try await store.save(
            png, filenameHint: "a", fileExtension: "png", kind: .fetchedImage, mimeType: "image/png"
        )

        // 同じセッション ID で再オープン → 台帳復元 + 内容ハッシュも復元（重複保存しない）
        let reopened = try MediaSessionStore(rootDirectory: root, sessionID: "s1")
        #expect(await reopened.allItems().count == 1)
        let again = try await reopened.save(
            png, filenameHint: "b", fileExtension: "png", kind: .fetchedImage, mimeType: "image/png"
        )
        #expect(again.reused == true)
    }

    @Test func slugifyNormalizesHints() {
        #expect(MediaSessionStore.slugify("Tokyo Tower View!") == "tokyo-tower-view")
        #expect(MediaSessionStore.slugify("  --- ") == "media")
        #expect(MediaSessionStore.slugify("東京タワー") == "media")
        #expect(MediaSessionStore.slugify("a_b/c d") == "a-b-c-d")
    }

    @Test func stableURLRoundTripsToFileURL() async throws {
        // sessionID は UUID 大文字 — URL host の大小文字正規化に巻き込まれないこと
        let sessionID = "ABC123DE-0000-4000-8000-1234567890AB"
        let root = makeTempRoot()
        let store = try MediaSessionStore(rootDirectory: root, sessionID: sessionID)
        let result = try await store.save(
            makePNG(width: 400, height: 300),
            filenameHint: "hero", fileExtension: "png", kind: .generatedImage, mimeType: "image/png"
        )

        let stable = store.stableURL(for: result.item)
        #expect(stable.absoluteString == "media://\(sessionID)/hero.png")

        let resolved = MediaSessionStore.fileURL(forStable: stable, rootDirectory: root)
        #expect(resolved?.path == result.fileURL.path)
    }

    @Test func fileURLForStableRejectsForeignURLs() {
        #expect(MediaSessionStore.fileURL(forStable: URL(string: "https://example.com/a.png")!) == nil)
        #expect(MediaSessionStore.fileURL(forStable: URL(string: "media://only-session-id")!) == nil)
    }
}

extension JSONDecoder {
    static var withISO8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
