import Foundation
#if canImport(ImagePlayground)
import CoreGraphics
import ImageIO
import ImagePlayground
import UniformTypeIdentifiers
#endif

/// オンデバイス画像生成のシーム。テストではモックに差し替える。
///
/// クラウド生成（`ImageGenerating`）とは役割を分ける:
/// クラウド = 高品質なコンセプトアート・図解、オンデバイス = UI 装飾用の軽量画像。
public protocol OnDeviceImageGenerating: Sendable {
    /// プロンプトとスタイル名から画像を 1 枚生成し、PNG バイト列を返す。
    /// 実行時に生成不能（Apple Intelligence 無効化・モデル未ダウンロード等）なら throw する。
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

/// Apple Image Playground（`ImageCreator`）によるオンデバイス画像生成。
///
/// 無料・API キー不要・オフライン動作。ただしスタイルは
/// animation / illustration / sketch のみで、写実・正確なテキスト描画・図解には不向き。
/// UI 装飾用途（背景・サムネイル・アクセント挿絵）専用として扱う。
public struct PlaygroundImageGenerator: OnDeviceImageGenerating {
    /// ツールスキーマの enum に使うスタイル名（ImagePlaygroundStyle と 1:1）。
    public static let styleNames = ["animation", "illustration", "sketch"]

    /// ツールセット構築時のゲート。false ならツール自体を編成に入れない。
    /// OS バージョンに加え、Apple Intelligence の有効化状態・対応ハードウェアを反映する。
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
            // isSupported を通っていても、モデル削除・設定変更等で実行時に落ちうる
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
