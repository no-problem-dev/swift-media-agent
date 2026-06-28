[English](./README.md) | 日本語

# swift-media-agent

A2A マルチエージェント構成で **UI に表示するメディア要素（画像・動画参照・チャート）を準備する専門エージェント**を実装するための Swift パッケージ。

リサーチ等のタスクを終えたオーケストレータが UI（A2UI surface）を描画する一歩手前で、
この visualizer エージェントに委譲してビジュアル素材を揃え、`media://` 安定 URL のマニフェストとして受け取る。UI へ渡す前に `MediaSessionStore.fileURL(forStable:)` で file URL へ解決する。

```
HostAgent ──send_message──> visualizer ──tools──> 生成 / 検索 / 検証 / 保存
                                 │
                                 └─> セッションディレクトリ + manifest.json
                                       └─> media:// 安定 URL → fileURL(forStable:) で解決してから A2UI へ
```

## 設計原則

1. **URL を信用せず、バイトを保存（リホスト）する** — リモート画像 URL は hotlink 防止・署名付き URL の期限切れ・将来の 404 でいつか必ず死ぬ。検証済みバイトをセッションディレクトリに保存すればすべて無効化される
2. **保存前に必ず検証する** — Content-Type ヘッダではなくマジックバイトで画像判定し、ImageIO で実寸法を確認、最小サイズ・極端なアスペクト比を弾く（HEAD は 405 を返すサーバがあるため使わない）
3. **数値データのチャートを画像生成 AI に描かせない** — Chart.js 宣言仕様 → 決定論的レンダリング（QuickChart）。仕様 JSON も manifest に保持し、将来のネイティブ（Swift Charts カタログ）描画へ移行可能
4. **検索 → 不適なら生成へフォールバック** — 実在物は検索、概念図・挿絵は生成、というルーティングを system prompt が指示する
5. **セッションスコープ + べき等** — Google ADK ArtifactService を踏襲。内容ハッシュで重複排除、同名はバージョン付与、manifest.json から復元可能

## ターゲット構成

| ターゲット | 責務 | 依存 |
|---|---|---|
| `MediaStore` | セッション別ファイルストア・manifest・画像バイト検証 | Foundation / ImageIO のみ |
| `MediaAgentTools` | LLM ツール群 + プロバイダー（Gemini 生成 / Serper 検索 / oEmbed / QuickChart） | MediaStore, LLMTool |
| `MediaAgent` | visualizer エージェントの定義（system prompt / AgentCard / ToolSet） | MediaAgentTools, A2ACore |

## 提供ツール

| ツール | 役割 |
|---|---|
| `generate_image` | Gemini 画像生成 → 検証 → 保存。概念図・挿絵・ヒーロー画像向け |
| `generate_ui_image` | Apple Image Playground オンデバイス生成 → 検証 → 保存。装飾用 UI 画像向け（Apple Intelligence 要） |
| `search_images` | Serper 画像検索。候補 URL とサイズを返す（保存はまだしない） |
| `save_image_url` | 画像 URL をダウンロード → マジックバイト/寸法/アスペクト比検証 → 保存 |
| `search_videos` | Serper 動画検索 |
| `save_video_reference` | YouTube oEmbed で存在検証 → サムネイル保存（maxres → hq フォールバック） |
| `create_chart` | Chart.js config → QuickChart → PNG 保存（chartSpec も台帳に保持） |
| `list_saved_media` | セッションの保存済みメディア一覧（最終マニフェスト作成用） |

## 使い方

```swift
import MediaAgent
import MediaAgentTools
import MediaStore

// 1. 会話セッションごとにストアを作る
let store = try MediaSessionStore(sessionID: sessionID)

// 2. ツールキットを組む（Serper キーが無ければ検索ツールは自動で外れる）
let toolKit = MediaToolKit.gemini(
    store: store,
    geminiAPIKey: geminiKey,
    serperAPIKey: serperKey,
    gl: "jp", hl: "ja"
)

// 3. 他のワーカーと同じ手順でエージェント化する（A2AResearchDemo の例）
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

visualizer の返答は `- kind | media URL | alt | suggested placement` 形式のマニフェスト。
`media://` 安定 URL は `MediaSessionStore.fileURL(forStable:)` で file URL へ解決してから A2UI の `Image.url` へ渡す。

## 既知の判断・制約

- **Gemini 画像生成は REST 直叩きの自己完結実装**（`GeminiImageGenerator`）。本来は swift-llm-cloud の責務だが、公開版 `GeminiImageModel` が旧世代のみ（Imagen 4 は 2026-06-24 シャットダウン、`gemini-2.0-flash-exp-image-generation` は廃止済み）のため、現行モデル `gemini-3.1-flash-image`（既定）/ `gemini-2.5-flash-image` / `gemini-3-pro-image` を文字列指定で使う。upstream のモデルカタログ更新後に差し替える
- `imageConfig.aspectRatio` は API リビジョン間でフィールド名が揺れているため、未知フィールドの 400 はアスペクト指定なしで 1 回リトライする
- 画像検索は Serper（Google Images）。Bing Image Search API は 2025-08 廃止、Google Custom Search JSON API は 2027-01 廃止予定のため採用しない
- 生成画像には SynthID（不可視透かし）が常に埋め込まれる（API 仕様）
- 動画は本体を保存せず「サムネイル + 参照 URL」。oEmbed の成功が存在検証を兼ねる
