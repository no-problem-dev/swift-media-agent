import Foundation
import ImageIO

/// マジックバイトで判定した画像フォーマット。
/// Content-Type ヘッダは偽装・誤設定が多い（エラーページが 200 + text/html で返る等）ため、
/// 保存可否は必ずバイト列で判定する。
public enum ImageByteFormat: String, Sendable, CaseIterable {
    case png
    case jpeg
    case gif
    case webp
    case heic

    public var mimeType: String {
        switch self {
        case .png: "image/png"
        case .jpeg: "image/jpeg"
        case .gif: "image/gif"
        case .webp: "image/webp"
        case .heic: "image/heic"
        }
    }

    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .gif: "gif"
        case .webp: "webp"
        case .heic: "heic"
        }
    }
}

/// 画像バイト列の検証ポリシー。
public struct ImageValidationPolicy: Sendable {
    /// 短辺の最小ピクセル数（アイコン・トラッカー画像の除外）
    public var minShortSide: Int
    /// 長辺/短辺 の最大比（バナー・スペーサーの除外）
    public var maxAspectRatio: Double
    /// 最大バイト数
    public var maxByteCount: Int
    /// 受け入れるフォーマット
    public var allowedFormats: Set<ImageByteFormat>

    public init(
        minShortSide: Int = 200,
        maxAspectRatio: Double = 4.0,
        maxByteCount: Int = 10 * 1024 * 1024,
        allowedFormats: Set<ImageByteFormat> = [.png, .jpeg, .gif, .webp, .heic]
    ) {
        self.minShortSide = minShortSide
        self.maxAspectRatio = maxAspectRatio
        self.maxByteCount = maxByteCount
        self.allowedFormats = allowedFormats
    }

    public static let `default` = ImageValidationPolicy()
}

/// 検証を通過した画像の情報。
public struct ValidatedImage: Sendable, Equatable {
    public let format: ImageByteFormat
    public let width: Int
    public let height: Int
}

/// `ImageDataInspector.validate(_:policy:)` が検証失敗時にスローするエラー。
///
/// `bodyPrefix` などの連想値には診断用の文脈情報が格納されるため、
/// ログや UI のフォールバックメッセージ生成に利用できる。
public enum ImageValidationError: Error, Sendable, Equatable, LocalizedError {
    /// 画像のマジックバイトではない（HTML エラーページ等）
    case notAnImage(bodyPrefix: String)
    case unsupportedFormat(ImageByteFormat)
    case undecodable
    case tooSmall(width: Int, height: Int, minShortSide: Int)
    case extremeAspectRatio(width: Int, height: Int, maxRatio: Double)
    case tooLarge(byteCount: Int, maxByteCount: Int)

    public var errorDescription: String? {
        switch self {
        case .notAnImage(let prefix):
            "Response is not an image (body starts with: \(prefix))"
        case .unsupportedFormat(let format):
            "Image format \(format.rawValue) is not allowed"
        case .undecodable:
            "Image bytes could not be decoded"
        case .tooSmall(let w, let h, let min):
            "Image \(w)x\(h) is too small (short side must be >= \(min)px)"
        case .extremeAspectRatio(let w, let h, let max):
            "Image \(w)x\(h) has an extreme aspect ratio (max \(max):1)"
        case .tooLarge(let count, let max):
            "Image is \(count) bytes (max \(max))"
        }
    }
}

/// 画像バイト列の判定・検証。純関数のみでネットワークに触れない。
public enum ImageDataInspector {

    /// マジックバイトからフォーマットを判定する。
    public static func sniffFormat(_ data: Data) -> ImageByteFormat? {
        guard data.count >= 12 else { return nil }
        let bytes = [UInt8](data.prefix(12))
        if bytes[0...3] == [0x89, 0x50, 0x4E, 0x47] { return .png }
        if bytes[0...2] == [0xFF, 0xD8, 0xFF] { return .jpeg }
        if bytes[0...3] == [0x47, 0x49, 0x46, 0x38] { return .gif }
        // WebP: "RIFF" .... "WEBP"
        if bytes[0...3] == [0x52, 0x49, 0x46, 0x46], bytes[8...11] == [0x57, 0x45, 0x42, 0x50] {
            return .webp
        }
        // HEIC/HEIF: offset 4 から "ftyp" + heic 系ブランド
        if bytes[4...7] == [0x66, 0x74, 0x79, 0x70] {
            let brand = String(bytes: bytes[8...11], encoding: .ascii) ?? ""
            if ["heic", "heix", "hevc", "mif1", "msf1"].contains(brand) { return .heic }
        }
        return nil
    }

    /// ImageIO でピクセル寸法を取得する（フルデコードしない）。
    public static func dimensions(of data: Data) -> (width: Int, height: Int)? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    /// ポリシーに従って画像バイト列を検証する。
    public static func validate(
        _ data: Data,
        policy: ImageValidationPolicy = .default
    ) throws(ImageValidationError) -> ValidatedImage {
        guard data.count <= policy.maxByteCount else {
            throw .tooLarge(byteCount: data.count, maxByteCount: policy.maxByteCount)
        }
        guard let format = sniffFormat(data) else {
            let prefix = String(data: data.prefix(64), encoding: .utf8) ?? "<binary>"
            throw .notAnImage(bodyPrefix: prefix)
        }
        guard policy.allowedFormats.contains(format) else {
            throw .unsupportedFormat(format)
        }
        guard let (width, height) = dimensions(of: data), width > 0, height > 0 else {
            throw .undecodable
        }
        let shortSide = min(width, height)
        guard shortSide >= policy.minShortSide else {
            throw .tooSmall(width: width, height: height, minShortSide: policy.minShortSide)
        }
        let ratio = Double(max(width, height)) / Double(shortSide)
        guard ratio <= policy.maxAspectRatio else {
            throw .extremeAspectRatio(width: width, height: height, maxRatio: policy.maxAspectRatio)
        }
        return ValidatedImage(format: format, width: width, height: height)
    }
}
