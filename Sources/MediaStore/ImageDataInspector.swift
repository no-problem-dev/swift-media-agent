import Foundation
import ImageIO

/// Format identified by sniffing the leading magic bytes of a byte stream.
///
/// Never taken from the `Content-Type` header: servers misreport it routinely — an error page
/// commonly arrives as HTTP 200 with `text/html` — so whether bytes are worth saving is decided
/// from the bytes alone.
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

/// Thresholds deciding whether bytes are worth keeping, tuned to reject tracking pixels,
/// icons and spacer banners rather than to judge image quality.
public struct ImageValidationPolicy: Sendable {
    /// Minimum pixels on the shorter side — the bar that excludes icons and tracking pixels.
    public var minShortSide: Int
    /// Largest tolerated long-side to short-side ratio, which is what excludes banners and spacers.
    public var maxAspectRatio: Double
    /// Size ceiling, checked before anything is sniffed or decoded.
    public var maxByteCount: Int
    /// Formats accepted after sniffing; bytes outside this set are rejected even though they decode.
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

/// What inspection established about bytes that passed. Callers take the file extension
/// and MIME type for the saved file from `format`.
public struct ValidatedImage: Sendable, Equatable {
    public let format: ImageByteFormat
    public let width: Int
    public let height: Int
}

/// Why `ImageDataInspector.validate(_:policy:)` refused a byte stream.
///
/// Associated values carry the diagnostic context — the offending dimensions, the actual byte
/// count, the first 64 bytes of a non-image body — so a log line or fallback message can name what
/// was wrong. Raised inside a tool call, the `errorDescription` is what the model reads back.
public enum ImageValidationError: Error, Sendable, Equatable, LocalizedError {
    /// The leading bytes match no known image format, typically an HTML error page served with a 200 status.
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

/// Byte-level inspection of image data: no network, no filesystem, no shared state.
public enum ImageDataInspector {

    /// Identifies the format from the leading magic bytes, without decoding the image.
    ///
    /// Returns `nil` for unrecognized data and for any stream shorter than 12 bytes.
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
        // HEIC/HEIF: "ftyp" at offset 4, followed by an heic-family brand
        if bytes[4...7] == [0x66, 0x74, 0x79, 0x70] {
            let brand = String(bytes: bytes[8...11], encoding: .ascii) ?? ""
            if ["heic", "heix", "hevc", "mif1", "msf1"].contains(brand) { return .heic }
        }
        return nil
    }

    /// Reads pixel dimensions from the image header through ImageIO, without decoding or caching pixels.
    ///
    /// Returns `nil` when the bytes cannot be read as an image at all.
    public static func dimensions(of data: Data) -> (width: Int, height: Int)? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    /// Applies every policy check and reports the format and dimensions of bytes that pass.
    ///
    /// Checks run cheapest first: byte count, magic-byte sniffing, the allowed-format set, and only
    /// then an ImageIO header read for the size and aspect-ratio limits. The first failing check
    /// throws and nothing beyond it is examined, so the error names one reason, not all of them.
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
