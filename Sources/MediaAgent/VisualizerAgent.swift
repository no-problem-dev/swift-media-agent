import A2ACore
import Foundation
import LLMClient
import LLMTool
import MediaAgentTools
import MediaStore

/// Everything that defines the visualizer agent, and none of the machinery that runs it.
///
/// Supplies the role (`systemPrompt(tools:language:)`), the self-description
/// (`agentCard(interfaceURL:protocolBinding:tools:)`) and the tools (`toolSet(_:)`), while
/// depending on no LLM client and no A2A executor. A host instantiates it the same way it
/// instantiates any other worker, for instance `LLMAgentExecutor` plus `A2AClient.inProcess`.
public enum VisualizerAgent {
    public static let name = "visualizer"
    public static let version = "0.1.0"

    /// Delegation blurb an orchestrator reads, assuming a fully equipped configuration.
    ///
    /// Worded to make callers state what each asset should show and its role in the UI, leaving the
    /// choice of tool to this agent.
    public static var agentDescription: String { agentDescription() }

    /// Builds the delegation blurb from the tools that are actually enabled.
    ///
    /// Pass the same set given to `MediaToolKit.tools(enabled:)` and `systemPrompt(tools:language:)`.
    /// Otherwise an orchestrator delegates work on the strength of a capability this agent has not
    /// been equipped to perform.
    ///
    /// - Parameter enabled: Tools the agent may use, which decides which capabilities are advertised.
    public static func agentDescription(tools enabled: Set<MediaToolID> = MediaToolID.allTools) -> String {
        var capabilities: [String] = []
        if enabled.contains(.searchImages) { capabilities.append("real web photos and figures") }
        if enabled.contains(.searchVideos) { capabilities.append("video references") }
        if enabled.contains(.createChart) { capabilities.append("data charts") }
        if enabled.contains(.generateImage) { capabilities.append("generated illustrations") }
        if enabled.contains(.generateUIImage) { capabilities.append("on-device decorative imagery") }
        let sourcing = capabilities.isEmpty
            ? "validated copies of the asset URLs you provide"
            : capabilities.joined(separator: ", ")
        // "Prefer real assets over generated ones" only means something when both are available.
        let preference = enabled.contains(.searchImages) && enabled.contains(.generateImage)
            ? ", preferring real web assets over generation"
            : ""
        return """
        Sources the media a rich UI needs — \(sourcing). Tell it what each asset should show and its role \
        in the UI; it decides how to source each one\(preference). Every asset is validated and \
        saved locally; replies with a manifest of stable media:// URLs that can be used directly as \
        Image URLs in the UI.
        """
    }

    /// Builds the system prompt from the tools that are actually enabled.
    ///
    /// The routing rule it encodes: subjects that exist in the world go to search, visuals that do
    /// not exist yet go to generation, and numeric data goes to a chart with no invented values.
    /// Routing lines are emitted per tool ID, so passing the same set given to
    /// `MediaToolKit.tools(enabled:)` leaves no mention of a tool the model was not given.
    ///
    /// - Parameters:
    ///   - enabled: Tools the agent may use; must match the set the toolkit was built with.
    ///   - language: Language for the prose of the reply. Media URLs and alt text are exempt and
    ///     may come back in English.
    public static func systemPrompt(
        tools enabled: Set<MediaToolID> = MediaToolID.allTools,
        language: String = "Japanese"
    ) -> SystemPrompt {
        // Subject-to-tool routing table; only lines for enabled tools are emitted.
        var routes: [String] = []
        if enabled.contains(.searchImages) {
            routes.append("anything plausibly published on the web (people, products, places, screenshots, official diagrams and figures from docs or articles) -> search_images then save_image_url")
        }
        if enabled.contains(.generateImage) {
            routes.append("visuals that do not exist yet (original concept art, custom hero/header art) -> generate_image")
        }
        if enabled.contains(.generateUIImage) {
            routes.append("purely decorative UI imagery where stylized output is fine (ambient backdrops, thumbnails, playful accents) -> generate_ui_image (free, on-device)")
        }
        if enabled.contains(.createChart) {
            routes.append("numeric data -> create_chart (never invent numbers)")
        }
        if enabled.contains(.searchVideos) {
            routes.append("talks/demos -> search_videos then save_video_reference")
        }
        let routing = routes.isEmpty
            // With every discovery tool off the save tools remain, so the agent still works as the
            // validator and store for URLs it is handed.
            ? "You have no search or generation tools in this configuration. Validate and save the asset URLs given in the task input with save_image_url / save_video_reference."
            : "Choose tools by what each asset depicts, not by how the request is phrased."
                + (enabled.contains(.searchImages) ? " Prefer what already exists:" : "")
                + " " + routes.joined(separator: "; ") + "."
        let validationFailure = enabled.contains(.generateImage)
            ? "If a downloaded candidate fails validation, try the next candidate; if none pass, fall back to generate_image."
            : "If a downloaded candidate fails validation, try the next candidate; if none pass, report it on a `not found:` line."
        return SystemPrompt {
            PromptComponent.role(
                "Visual asset preparation agent. Prepare the media assets the UI needs to present the given content."
            )
            PromptComponent.instruction(routing)
            PromptComponent.instruction(
                "Remote URLs are not deliverables. Always validate and SAVE assets locally; only saved media:// URLs count as results."
            )
            PromptComponent.instruction(validationFailure)
            PromptComponent.instruction(
                "Prepare a small, curated set (typically 1-5 assets) that best supports the content. Quality over quantity."
            )
            PromptComponent.instruction(
                "Before your final reply, call list_saved_media and base the manifest on it."
            )
            PromptComponent.constraint("""
            Verified-only: mention an entity (channel, video, product, person) ONLY if a tool verified it this session. \
            If something you were asked to cover could not be found or failed validation, report it on a `not found:` \
            line so the caller omits it — never substitute an unverified alternative or a guessed URL.
            """)
            PromptComponent.outputConstraint("""
            Reply with a media manifest: one line per VERIFIED asset in the form \
            `- kind | media URL | alt/description | suggested placement`, followed by video URLs for video references, \
            then `not found:` lines for anything requested but unverifiable. \
            Copy media:// URLs exactly. Reply concisely in \(language) (media URLs and alt text may stay in English).
            """)
        }
    }

    /// A2A card advertising the agent, its skill list derived from the enabled tools.
    ///
    /// `interfaceURL` and `protocolBinding` describe how this particular deployment is reached —
    /// in-process or over HTTP — and are the caller's to decide. Pass the same `tools` set used
    /// everywhere else so the advertised skills match what the agent can actually do.
    public static func agentCard(
        interfaceURL: String,
        protocolBinding: String = "InProcess",
        tools enabled: Set<MediaToolID> = MediaToolID.allTools
    ) -> AgentCard {
        var skills: [AgentSkill] = []
        if enabled.contains(.generateImage) {
            skills.append(AgentSkill(
                id: "generate-image",
                name: "Generate images",
                description: "Generates concept art, illustrations and diagrams with an AI image model and stores them locally.",
                tags: ["media", "image", "generation"]
            ))
        }
        if enabled.contains(.generateUIImage) {
            skills.append(AgentSkill(
                id: "generate-ui-image",
                name: "On-device decorative images",
                description: "Generates stylized decorative imagery (animation/illustration/sketch) on-device with Apple Image Playground and stores it locally.",
                tags: ["media", "image", "generation", "on-device"]
            ))
        }
        if enabled.contains(.searchImages) {
            skills.append(AgentSkill(
                id: "fetch-images",
                name: "Find and validate web images",
                description: "Searches the web for images, validates the bytes (format, size, aspect), and rehosts them locally.",
                tags: ["media", "image", "search", "validation"]
            ))
        }
        if enabled.contains(.searchVideos) {
            skills.append(AgentSkill(
                id: "video-references",
                name: "Video references",
                description: "Verifies YouTube videos via oEmbed and stores thumbnails with video links.",
                tags: ["media", "video"]
            ))
        }
        if enabled.contains(.createChart) {
            skills.append(AgentSkill(
                id: "charts",
                name: "Data charts",
                description: "Renders accurate data charts from declarative chart specs (Chart.js) as PNG files.",
                tags: ["media", "chart", "data"]
            ))
        }
        return AgentCard(
            name: name,
            description: agentDescription(tools: enabled),
            supportedInterfaces: [AgentInterface(url: interfaceURL, protocolBinding: protocolBinding)],
            version: version,
            capabilities: AgentCapabilities(streaming: true),
            skills: skills
        )
    }

    /// Wraps a toolkit's tools as a `ToolSet` for handing to an `LLMAgentExecutor`.
    ///
    /// - Important: This takes `MediaToolKit.tools`, which is every tool the configured providers
    ///   can supply, and has no way to observe a narrower selection. A configuration that disables
    ///   tools must build its `ToolSet` from `MediaToolKit.tools(enabled:)` with the same set given
    ///   to `systemPrompt(tools:language:)`, or the model will hold tools the prompt never mentions.
    public static func toolSet(_ toolKit: MediaToolKit) -> ToolSet {
        ToolSet(tools: toolKit.tools)
    }
}
