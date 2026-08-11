/// The single vocabulary for switching visualizer tools on and off.
///
/// Pass one and the same set to `MediaToolKit.tools(enabled:)`,
/// `VisualizerAgent.systemPrompt(tools:language:)` and `VisualizerAgent.agentDescription(tools:)`:
/// each prunes itself against that set, so the tools that exist, the tools the prompt talks about,
/// and the capabilities advertised for delegation stay in agreement. Passing different sets is what
/// makes a prompt instruct the model to call a tool it was never given.
///
/// User-facing copy for these tools belongs to the host's UI layer, not here.
public enum MediaToolID: String, CaseIterable, Codable, Hashable, Sendable {
    case generateImage = "generate_image"
    case generateUIImage = "generate_ui_image"
    case searchImages = "search_images"
    case saveImageURL = "save_image_url"
    case searchVideos = "search_videos"
    case saveVideoReference = "save_video_reference"
    case createChart = "create_chart"
    case listSavedMedia = "list_saved_media"

    /// Survives every `enabled` set, because the manifest machinery does not work without it.
    ///
    /// The save tools stay because they also validate and store URLs the host supplies directly;
    /// `list_saved_media` stays because the final reply's manifest is built from its output.
    public var isCore: Bool {
        switch self {
        case .saveImageURL, .saveVideoReference, .listSavedMedia: true
        case .generateImage, .generateUIImage, .searchImages, .searchVideos, .createChart: false
        }
    }

    /// Needs a web search provider such as Serper.
    ///
    /// Without one the tool is dropped from the toolkit even when `enabled` names it, so the model
    /// never sees it and never fails on it.
    public var requiresSearchProvider: Bool {
        switch self {
        case .searchImages, .searchVideos: true
        default: false
        }
    }

    /// Needs a cloud image generation model, which in the stock configuration means a Gemini API key.
    ///
    /// A toolkit built without a generator drops the tool rather than letting it fail at call time.
    public var requiresImageGenerator: Bool {
        self == .generateImage
    }

    /// Needs on-device generation through Apple Image Playground, which requires Apple Intelligence
    /// and a downloaded image model.
    ///
    /// Hosts gate on `PlaygroundImageGenerator.isSupported` and pass no generator otherwise, which
    /// drops the tool instead of exposing one that cannot run on this device.
    public var requiresOnDeviceImageGenerator: Bool {
        self == .generateUIImage
    }

    /// The floor of every configuration: `MediaToolKit.tools(enabled:)` unions this into whatever
    /// set it is handed.
    public static let coreTools: Set<MediaToolID> = Set(allCases.filter(\.isCore))

    /// Every case, and the default wherever an `enabled` set is accepted.
    public static let allTools: Set<MediaToolID> = Set(allCases)
}
