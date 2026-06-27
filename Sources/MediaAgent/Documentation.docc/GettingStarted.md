# Getting Started with MediaAgent

VisualizerAgent の組み立てと、オーケストレータへの統合方法。

## Installation

`Package.swift` の `dependencies` に追加します:

```swift
.package(url: "https://github.com/no-problem-dev/swift-media-agent.git", from: "0.1.0")
```

ターゲットの `dependencies` に `MediaAgent` を追加します（推移的に `MediaAgentTools` と `MediaStore` も解決されます）:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "MediaAgent", package: "swift-media-agent")
    ]
)
```

## Basic Usage

### フル構成（Gemini 画像生成 + Serper 検索）

```swift
import MediaAgent
import MediaAgentTools
import MediaStore

let store = try MediaSessionStore(sessionID: sessionID)

let kit = MediaToolKit.gemini(
    store: store,
    geminiAPIKey: ProcessInfo.processInfo.environment["GEMINI_API_KEY"]!,
    serperAPIKey: ProcessInfo.processInfo.environment["SERPER_API_KEY"],
    gl: "jp",
    hl: "ja"
)

// システムプロンプト・AgentCard・ToolSet は同じ availableToolIDs から生成する
let systemPrompt = VisualizerAgent.systemPrompt(tools: kit.availableToolIDs)
let toolSet = VisualizerAgent.toolSet(kit)
let agentCard = VisualizerAgent.agentCard(
    interfaceURL: "inprocess://visualizer",
    tools: kit.availableToolIDs
)
```

### ツールの選択的有効化

```swift
// 画像生成を無効化して検索のみ使う
let searchOnly = MediaToolID.allTools.subtracting([.generateImage, .generateUIImage])
let tools = kit.tools(enabled: searchOnly)
let prompt = VisualizerAgent.systemPrompt(tools: searchOnly)
// → プロンプト内の generate_image への言及も自動的に除去される
```

### オンデバイス生成（Apple Image Playground）の追加

```swift
let onDevice: (any OnDeviceImageGenerating)? = await MainActor.run {
    PlaygroundImageGenerator.isSupported ? PlaygroundImageGenerator() : nil
}

let kit = MediaToolKit.gemini(
    store: store,
    geminiAPIKey: geminiKey,
    onDeviceImageGenerator: onDevice  // nil なら generate_ui_image ツールが編成から外れる
)
```

### ミニマル構成（検索・生成なし）

外部 API キーなしでも `save_image_url` / `save_video_reference` / `create_chart` / `list_saved_media` の 4 コアツールは常に提供されます。

```swift
let kit = MediaToolKit(store: store)  // http は URLSession デフォルト
let tools = kit.tools                 // コア 4 ツール + create_chart
```
