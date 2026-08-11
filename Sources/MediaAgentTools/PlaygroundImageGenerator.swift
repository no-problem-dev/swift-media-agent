import Foundation
#if canImport(ImagePlayground)
import CoreGraphics
import ImageIO
import ImagePlayground
import UniformTypeIdentifiers
#endif

/// Seam for on-device image generation, substituted with a mock in tests.
///
/// Kept apart from `ImageGenerating` because the two are not interchangeable: the cloud model is
/// for concept art and diagrams that need fidelity, this one for lightweight decorative imagery
/// where a stylized result is acceptable.
public protocol OnDeviceImageGenerating: Sendable {
    /// Generates a single image and returns it as PNG bytes.
    ///
    /// - Parameters:
    ///   - prompt: Short English prompt covering subject, mood and colors.
    ///   - style: One of `"animation"`, `"illustration"` or `"sketch"`.
    /// - Throws: `OnDeviceImageError.notSupported` when the device lacks Apple Intelligence or has
    ///   not downloaded the image model.
    func generateImage(prompt: String, style: String) async throws -> Data
}

public enum OnDeviceImageError: Error, Sendable, LocalizedError {
    case notSupported
    case unsupportedStyle(requested: String, available: [String])
    case emptyResult
    case encodingFailed
    case generationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notSupported:
            "On-device image generation is not available right now (requires Apple Intelligence with the image model downloaded)."
        case .unsupportedStyle(let requested, let available):
            "Style '\(requested)' is not available on this device. Available styles: \(available.joined(separator: ", "))."
        case .emptyResult:
            "On-device image generation returned no image."
        case .encodingFailed:
            "Failed to encode the generated image as PNG."
        case .generationFailed(let reason):
            "On-device image generation failed: \(reason)"
        }
    }
}

/// On-device generation through Apple Image Playground's `ImageCreator`.
///
/// Free, offline and needs no API key, but confined to the animation, illustration and sketch
/// styles: no photorealism, no legible text, no accurate diagrams. Treat it as a source of UI
/// decoration — backdrops, thumbnails, spot illustrations — and nothing else.
public struct PlaygroundImageGenerator: OnDeviceImageGenerating {
    /// Style names used verbatim as the tool schema's enum, one per `ImagePlaygroundStyle` case.
    public static let styleNames = ["animation", "illustration", "sketch"]

    /// Gate to check before building the toolkit: when this is false the host passes no generator
    /// and `generate_ui_image` is left out entirely.
    ///
    /// Covers more than the OS version — it also reflects whether Apple Intelligence is enabled and
    /// whether the hardware supports it. Passing the gate is still no guarantee, since the model can
    /// be removed or disabled between this check and the call.
    @MainActor
    public static var isSupported: Bool {
        #if canImport(ImagePlayground)
        guard #available(iOS 18.4, macOS 15.4, macCatalyst 18.4, visionOS 2.4, *) else { return false }
        return ImagePlaygroundViewController.isAvailable
        #else
        return false
        #endif
    }

    public init() {}

    public func generateImage(prompt: String, style: String) async throws -> Data {
        #if canImport(ImagePlayground)
        guard #available(iOS 18.4, macOS 15.4, macCatalyst 18.4, visionOS 2.4, *) else {
            throw OnDeviceImageError.notSupported
        }
        let playgroundStyle: ImagePlaygroundStyle
        switch style {
        case "animation": playgroundStyle = .animation
        case "illustration": playgroundStyle = .illustration
        case "sketch": playgroundStyle = .sketch
        default:
            throw OnDeviceImageError.unsupportedStyle(requested: style, available: Self.styleNames)
        }

        let creator: ImageCreator
        do {
            creator = try await ImageCreator()
        } catch {
            // Clearing isSupported does not prevent this: the model can be deleted or the setting
            // changed between the gate and this call.
            throw OnDeviceImageError.generationFailed(String(describing: error))
        }
        guard creator.availableStyles.contains(playgroundStyle) else {
            throw OnDeviceImageError.unsupportedStyle(
                requested: style,
                available: creator.availableStyles.compactMap { available in
                    Self.styleNames.first { name in
                        switch name {
                        case "animation": available == .animation
                        case "illustration": available == .illustration
                        case "sketch": available == .sketch
                        default: false
                        }
                    }
                }
            )
        }

        do {
            for try await created in creator.images(for: [.text(prompt)], style: playgroundStyle, limit: 1) {
                return try Self.pngData(from: created.cgImage)
            }
        } catch let error as OnDeviceImageError {
            throw error
        } catch {
            throw OnDeviceImageError.generationFailed(String(describing: error))
        }
        throw OnDeviceImageError.emptyResult
        #else
        throw OnDeviceImageError.notSupported
        #endif
    }

    #if canImport(ImagePlayground)
    private static func pngData(from cgImage: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ) else { throw OnDeviceImageError.encodingFailed }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw OnDeviceImageError.encodingFailed
        }
        return data as Data
    }
    #endif
}
