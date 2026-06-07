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

    /// オーケストレータが委譲判断に使う説明。
    /// WHAT（被写体・データ・UI 上の役割）を渡させ、HOW（ツール選択）は委譲先に残す。
    public static let agentDescription = """
    Sources the media a rich UI needs — real web photos and figures, video references, data charts, \
    generated illustrations. Tell it what each asset should show and its role in the UI; it decides \
    how to source each one, preferring real web assets over generation. Every asset is validated and \
    saved as a local file; replies with a manifest of local file URLs that can be used directly as \
    Image URLs in the UI.
    """

    /// visualizer の system prompt。
    ///
    /// ルーティング方針は Manus / Genspark の収束点を踏襲:
    /// 実在物 → 検索、概念図・挿絵 → 生成、数値データ → チャート（数値の捏造禁止）。
    public static func systemPrompt() -> SystemPrompt {
        SystemPrompt {
            PromptComponent.role(
                "Visual asset preparation agent. Prepare the media assets the UI needs to present the given content."
            )
            PromptComponent.instruction(
                "Choose tools by what each asset depicts, not by how the request is phrased. Prefer what already exists: anything plausibly published on the web (people, products, places, screenshots, official diagrams and figures from docs or articles) -> search_images then save_image_url; visuals that do not exist yet (original concept art, custom hero/header art) -> generate_image; numeric data -> create_chart (never invent numbers); talks/demos -> search_videos then save_video_reference."
            )
            PromptComponent.instruction(
                "Remote URLs are not deliverables. Always validate and SAVE assets locally; only local file URLs count as results."
            )
            PromptComponent.instruction(
                "If a downloaded candidate fails validation, try the next candidate; if none pass, fall back to generate_image."
            )
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
            `- kind | file URL | alt/description | suggested placement`, followed by video URLs for video references, \
            then `not found:` lines for anything requested but unverifiable. \
            Copy file URLs exactly. Reply concisely in Japanese (file URLs and alt text may stay in English).
            """)
        }
    }

    /// A2A AgentCard。`interfaceURL` は配置形態（in-process / HTTP）に応じて呼び出し側が決める。
    public static func agentCard(
        interfaceURL: String,
        protocolBinding: String = "InProcess"
    ) -> AgentCard {
        AgentCard(
            name: name,
            description: agentDescription,
            supportedInterfaces: [AgentInterface(url: interfaceURL, protocolBinding: protocolBinding)],
            version: version,
            capabilities: AgentCapabilities(streaming: true),
            skills: [
                AgentSkill(
                    id: "generate-image",
                    name: "Generate images",
                    description: "Generates concept art, illustrations and diagrams with an AI image model and stores them locally.",
                    tags: ["media", "image", "generation"]
                ),
                AgentSkill(
                    id: "fetch-images",
                    name: "Find and validate web images",
                    description: "Searches the web for images, validates the bytes (format, size, aspect), and rehosts them locally.",
                    tags: ["media", "image", "search", "validation"]
                ),
                AgentSkill(
                    id: "video-references",
                    name: "Video references",
                    description: "Verifies YouTube videos via oEmbed and stores thumbnails with video links.",
                    tags: ["media", "video"]
                ),
                AgentSkill(
                    id: "charts",
                    name: "Data charts",
                    description: "Renders accurate data charts from declarative chart specs (Chart.js) as PNG files.",
                    tags: ["media", "chart", "data"]
                ),
            ]
        )
    }

    /// ツール一式を ToolSet として返す。
    public static func toolSet(_ toolKit: MediaToolKit) -> ToolSet {
        ToolSet(tools: toolKit.tools)
    }
}
