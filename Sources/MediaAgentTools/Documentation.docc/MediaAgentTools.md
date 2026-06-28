# ``MediaAgentTools``

visualizer エージェントにメディア調達能力を与えるツール実装層。画像生成・検索・チャートレンダリング・動画参照を `MediaToolKit` 一点でアセンブルする。

## Overview

`MediaAgentTools` は `MediaToolKit` を中心に構成されたツール実装モジュール。
クラウド画像生成（Gemini）・オンデバイス生成（Apple Image Playground）・Web 画像検索（Serper）・データチャート（QuickChart.io）・YouTube 動画参照の 5 種類の能力を、`MediaToolID` というツール ID の集合によって選択的に組み合わせられる。

`MediaToolKit` の初期化には `MediaStore.MediaSessionStore` を渡す。取得・生成したバイトはすべて `MediaStore` のセッションディレクトリに検証・保存されるため、ホットリンク切れや署名期限切れに依存しないリホスト済みアセットが得られる。

```swift
import MediaAgent
import MediaAgentTools
import MediaStore

// 1. セッションストアを作成（MediaStore）
let store = try MediaSessionStore(sessionID: "session-\(UUID().uuidString)")

// 2. Gemini 画像生成 + Serper 検索の標準構成
let kit = MediaToolKit.gemini(
    store: store,
    geminiAPIKey: geminiKey,
    serperAPIKey: serperKey
)

// 3. 有効なツール ID を確認してから LLM に渡す
let available = kit.availableToolIDs
// → [.generateImage, .searchImages, .searchVideos, .saveImageURL, .saveVideoReference,
//    .createChart, .listSavedMedia]

// 4. ツール一式・プロンプト・AgentCard を同じ ID セットから導出
let tools = kit.tools(enabled: available)
let prompt = VisualizerAgent.systemPrompt(tools: available)
```

### ツール選択の設計方針

`MediaToolID` の `isCore` プロパティが `true` のツール（`saveImageURL`, `saveVideoReference`, `listSavedMedia`）は無効化できないコアツールだ。
`generateImage`, `generateUIImage`, `searchImages`, `searchVideos`, `createChart` はプロバイダが構成されている場合のみ `availableToolIDs` に現れ、未構成のまま `enabled` に含めても提供されない。

```swift
// カスタム構成：チャートと URL 保存のみ（検索・生成なし）
let minimalKit = MediaToolKit(store: store)
// availableToolIDs: [.saveImageURL, .saveVideoReference, .createChart, .listSavedMedia]
let tools = minimalKit.tools(enabled: [.createChart])
```

### 検証パイプライン

すべての画像アセット（URL 取得・クラウド生成・オンデバイス生成）は保存前に `MediaStore.ImageDataInspector` によるマジックバイト・寸法・アスペクト比の検証を通過します。検証を通過したバイトのみがセッションディレクトリに保存され、`media://` スキームの安定 URL が返されます。

## Topics

### ツールキット

- ``MediaToolKit``
- ``MediaToolID``

### クラウド画像生成

- ``ImageGenerating``
- ``GeminiImageGenerator``
- ``ImageGeneratorError``

### オンデバイス画像生成

- ``OnDeviceImageGenerating``
- ``PlaygroundImageGenerator``
- ``OnDeviceImageError``

### 画像検索

- ``ImageSearchProvider``
- ``ImageSearchHit``
- ``SerperMediaSearchProvider``

### 動画検索

- ``VideoSearchProvider``
- ``VideoSearchHit``

### チャートレンダリング

- ``ChartRendering``
- ``QuickChartRenderer``
- ``ChartRenderError``

### YouTube 動画参照

- ``YouTubeOEmbed``
- ``VideoEmbedInfo``
- ``YouTubeOEmbedError``

### HTTP クライアント

- ``MediaHTTPClient``
- ``URLSessionMediaHTTPClient``
- ``MediaHTTPError``
