/// visualizer のツール ID 一覧（SSOT）。
///
/// ホストはこの ID でツールの有効/無効を選び、同じセットを
/// `MediaToolKit.tools(enabled:)` と `VisualizerAgent.systemPrompt(tools:)` /
/// `VisualizerAgent.agentDescription(tools:)` の全てへ渡す —
/// ツール一式・プロンプトの言及・委譲ルーティングの自己記述が常に一致する。
/// 表示用コピー（日本語要約など）はホスト UI 層が所有する。
public enum MediaToolID: String, CaseIterable, Codable, Hashable, Sendable {
    case generateImage = "generate_image"
    case generateUIImage = "generate_ui_image"
    case searchImages = "search_images"
    case saveImageURL = "save_image_url"
    case searchVideos = "search_videos"
    case saveVideoReference = "save_video_reference"
    case createChart = "create_chart"
    case listSavedMedia = "list_saved_media"

    /// マニフェスト機構の土台で、無効化できないツール。
    /// save 系はホストから渡された URL の検証・保存にも使われ、
    /// list_saved_media は最終マニフェストの根拠なので常に同伴する。
    public var isCore: Bool {
        switch self {
        case .saveImageURL, .saveVideoReference, .listSavedMedia: true
        case .generateImage, .generateUIImage, .searchImages, .searchVideos, .createChart: false
        }
    }

    /// 動作に Web 検索プロバイダ（Serper 等）が要るツール。
    /// プロバイダ未構成なら enabled に含めても提供されない。
    public var requiresSearchProvider: Bool {
        switch self {
        case .searchImages, .searchVideos: true
        default: false
        }
    }

    /// 動作に画像生成モデルが要るツール。
    public var requiresImageGenerator: Bool {
        self == .generateImage
    }

    /// 動作にオンデバイス画像生成（Apple Image Playground）が要るツール。
    /// デバイス非対応なら enabled に含めても提供されない。
    public var requiresOnDeviceImageGenerator: Bool {
        self == .generateUIImage
    }

    /// 無効化できないコアツールのセット。
    public static let coreTools: Set<MediaToolID> = Set(allCases.filter(\.isCore))

    /// 全ツールのセット（デフォルト = 全部オン）。
    public static let allTools: Set<MediaToolID> = Set(allCases)
}
