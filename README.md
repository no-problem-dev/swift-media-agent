English | [日本語](./README.ja.md)

# swift-media-agent

A Swift package for implementing a **visual asset preparation specialist agent** in A2A multi-agent architectures — sourcing images, video references, and charts for UI display.

An orchestrator that finishes a research task delegates to this visualizer agent to gather visual assets, and receives back a manifest of `media://` stable URLs; call `MediaSessionStore.fileURL(forStable:)` to resolve each URL to a local file URL before passing to the UI (A2UI surface).

```
HostAgent ──send_message──> visualizer ──tools──> generate / search / validate / save
                                 │
                                 └─> session directory + manifest.json
                                       └─> media:// stable URLs → fileURL(forStable:) before A2UI
```

## Design Principles

1. **Rehosts bytes, never trusts URLs** — Remote image URLs will eventually break (hotlink protection, expiring signed URLs, future 404s). Saving validated bytes locally eliminates all of these.
2. **Always validate before saving** — Images are checked by magic bytes (not Content-Type headers), then decoded with ImageIO to verify dimensions, minimum size, and aspect ratio (HEAD requests are skipped because some servers return 405).
3. **Never use image generation AI for numeric charts** — Uses declarative Chart.js specs → deterministic rendering (QuickChart). The spec JSON is kept in the manifest for future native (Swift Charts) rendering.
4. **Search first, generate as fallback** — Real-world subjects use search; concept art and illustrations use generation; the system prompt instructs this routing.
5. **Session-scoped + idempotent** — Follows Google ADK ArtifactService: SHA-256 deduplication, versioned filenames on collision, recoverable from manifest.json.

## Target Structure

| Target | Responsibility | Dependencies |
|---|---|---|
| `MediaStore` | Session-scoped file store, manifest, image byte validation | Foundation / ImageIO only |
| `MediaAgentTools` | LLM tool set + providers (Gemini generation / Serper search / oEmbed / QuickChart) | MediaStore, LLMTool |
| `MediaAgent` | Visualizer agent definition (system prompt / AgentCard / ToolSet) | MediaAgentTools, A2ACore |

## Available Tools

| Tool | Role |
|---|---|
| `generate_image` | Gemini image generation → validation → save. For concept art, illustrations, hero images. |
| `generate_ui_image` | Apple Image Playground on-device generation → validation → save. For decorative UI imagery. Requires Apple Intelligence. |
| `search_images` | Serper image search. Returns candidate URLs with sizes (not saved yet). |
| `save_image_url` | Download image URL → magic byte/dimension/aspect ratio validation → save. |
| `search_videos` | Serper video search. |
| `save_video_reference` | Verify via YouTube oEmbed → save thumbnail (maxres → hq fallback). |
| `create_chart` | Chart.js config → QuickChart → PNG save (chartSpec also stored in manifest). |
| `list_saved_media` | List all saved media in the session (for final manifest creation). |

## Usage

```swift
import MediaAgent
import MediaAgentTools
import MediaStore

// 1. Create a store per conversation session
let store = try MediaSessionStore(sessionID: sessionID)

// 2. Assemble the toolkit (search tools are excluded automatically if Serper key is absent)
let toolKit = MediaToolKit.gemini(
    store: store,
    geminiAPIKey: geminiKey,
    serperAPIKey: serperKey,
    gl: "jp", hl: "ja"
)

// 3. Initialize the agent using the same procedure as other workers (see A2AResearchDemo)
let executor = LLMAgentExecutor(
    client: gemini,
    model: model,
    tools: VisualizerAgent.toolSet(toolKit),
    systemPrompt: VisualizerAgent.systemPrompt(),
    maxSteps: 16
)
let card = VisualizerAgent.agentCard(interfaceURL: "inprocess://visualizer")
let client = A2AClient.inProcess(handler: DefaultRequestHandler(agentCard: card, executor: executor))
```

The visualizer's reply is a manifest in the format `- kind | media URL | alt | suggested placement`.
`media://` stable URLs must be resolved to file URLs via `MediaSessionStore.fileURL(forStable:)` before passing to A2UI's `Image.url`.

## Known Decisions & Constraints

- **Gemini image generation is a self-contained REST implementation** (`GeminiImageGenerator`). It belongs in swift-llm-cloud, but the public `GeminiImageModel` only supports legacy models (Imagen 4 shut down 2026-06-24, `gemini-2.0-flash-exp-image-generation` is deprecated). Current models — `gemini-3.1-flash-image` (default) / `gemini-2.5-flash-image` / `gemini-3-pro-image` — are specified by string until upstream updates its model catalog.
- `imageConfig.aspectRatio` field names vary across API revisions; a 400 error for unknown fields retries once without aspect ratio.
- Image search uses Serper (Google Images). Bing Image Search API was retired in 2025-08; Google Custom Search JSON API is planned for retirement in 2027-01.
- Generated images always have SynthID (invisible watermark) embedded per API specification.
- Videos are stored as "thumbnail + reference URL" only — the video itself is never saved. Successful oEmbed serves as the existence verification.
