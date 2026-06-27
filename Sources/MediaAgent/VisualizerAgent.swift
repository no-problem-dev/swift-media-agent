import A2ACore
import Foundation
import LLMClient
import LLMTool
import MediaAgentTools
import MediaStore

/// visualizer エージェントの定義一式。
///
/// 実行系（LLM クライアント・A2A executor）には依存せず、
/// 「役割（system prompt）・自己記述（AgentCard）・道具（ToolSet）」だけを提供する。
/// ホスト側は他のワーカーと同じ手順（LLMAgentExecutor + A2AClient.inProcess 等）で実体化する。
public enum VisualizerAgent {
    public static let name = "visualizer"
    public static let version = "0.1.0"

    /// オーケストレータが委譲判断に使う説明（全ツール構成のデフォルト）。
    /// WHAT（被写体・データ・UI 上の役割）を渡させ、HOW（ツール選択）は委譲先に残す。
    public static var agentDescription: String { agentDescription() }

    /// オーケストレータが委譲判断に使う説明を、有効ツール構成から組み立てる。
    /// `MediaToolKit.tools(enabled:)` / `systemPrompt(tools:)` と同じセットを渡すこと —
    /// ホストが「できる」と聞かされた能力と実際の道具が一致する。
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
        // 「検索を生成より優先」は両方あるときだけ意味を持つ。
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

    /// visualizer の system prompt を有効ツール構成から組み立てる。
    ///
    /// ルーティング方針は Manus / Genspark の収束点を踏襲:
    /// 実在物 → 検索、概念図・挿絵 → 生成、数値データ → チャート（数値の捏造禁止）。
    /// ルーティング指示はツール ID 単位の断片で、`MediaToolKit.tools(enabled:)` と同じ
    /// セットを渡せば「持っていないツールへの言及」がプロンプトに残らない。
    public static func systemPrompt(
        tools enabled: Set<MediaToolID> = MediaToolID.allTools,
        language: String = "Japanese"
    ) -> SystemPrompt {
        // 被写体 → ツールのルーティング表。有効なツールの行だけが並ぶ。
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
            // 探索系が全て無効でも save 系は残る — 渡された URL の検証・保存役として動く。
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

    /// A2A AgentCard。`interfaceURL` は配置形態（in-process / HTTP）に応じて呼び出し側が決める。
    /// スキル一覧も有効ツール構成から導出する（説明・プロンプト・ツールと同じセット）。
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

    /// `MediaToolKit` のツール一式を `ToolSet` としてラップする。
    ///
    /// `LLMAgentExecutor` に渡す際のアダプター。`systemPrompt(tools:)` と同じ `enabled` セットで
    /// 構築した `MediaToolKit.tools` を内包するため、プロンプトとツールの整合が保たれる。
    public static func toolSet(_ toolKit: MediaToolKit) -> ToolSet {
        ToolSet(tools: toolKit.tools)
    }
}
