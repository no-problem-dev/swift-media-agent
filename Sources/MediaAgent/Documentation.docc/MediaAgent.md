# ``MediaAgent``

visualizer エージェントの定義層。システムプロンプト・AgentCard・ToolSet を有効ツール構成から導出する。

## Overview

`MediaAgent` は `VisualizerAgent` という 1 つの名前空間型を提供する。実行系（LLM クライアント・A2A executor）には依存せず、「役割（system prompt）・自己記述（AgentCard）・道具（ToolSet）」の 3 点を組み立てる責務のみを担う。

**設計の核心**: 有効ツール ID (`Set<MediaToolID>`) を唯一の入力とし、プロンプト・AgentCard・ToolSet の 3 要素を同じセットから生成することで整合性を保証する。

このパッケージは 3 つのライブラリモジュールで構成される。

- **`MediaAgent`**（このモジュール）— エージェント定義層。`VisualizerAgent` がシステムプロンプト・A2A `AgentCard`・`ToolSet` を有効ツール構成から導出する。実行系には依存しないため、任意の LLM クライアント・A2A executor と組み合わせられる。
- **`MediaAgentTools`** — ツール実装層。`MediaToolKit` が画像生成（クラウド・オンデバイス）・Web 画像検索・チャートレンダリング・YouTube 動画参照の LLM ツールをアセンブルする。どの能力を有効にするかは `MediaToolID` の集合で制御する。
- **`MediaStore`** — ストレージ層。`MediaSessionStore` が取得・生成した画像バイトをセッション単位で保存し `manifest.json` で台帳化する。SHA-256 重複排除と `media://` スキームの安定 URL を提供し、iOS コンテナ UUID の変化に対してロバストな参照を実現する。

```swift
import MediaAgent
import MediaAgentTools
import MediaStore

// 1. ストアを作成
let store = try MediaSessionStore(sessionID: sessionID)

// 2. Gemini + Serper 構成の ToolKit を作成
let kit = MediaToolKit.gemini(
    store: store,
    geminiAPIKey: geminiKey,
    serperAPIKey: serperKey
)

// 3. 同じツールセットからプロンプト・カード・ツールを導出
let tools = kit.tools                                    // [any Tool]
let prompt = VisualizerAgent.systemPrompt(tools: kit.availableToolIDs)
let card = VisualizerAgent.agentCard(
    interfaceURL: "inprocess://visualizer",
    tools: kit.availableToolIDs
)
let toolSet = VisualizerAgent.toolSet(kit)              // ToolSet for LLMAgentExecutor
```

## Topics

### はじめに

- <doc:GettingStarted>

### エージェント定義

- ``VisualizerAgent``
