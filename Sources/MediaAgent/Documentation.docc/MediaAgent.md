# ``MediaAgent``

visualizer エージェントの定義層。システムプロンプト・AgentCard・ToolSet を有効ツール構成から導出する。

## Overview

`MediaAgent` は `VisualizerAgent` という 1 つの名前空間型を提供します。実行系（LLM クライアント・A2A executor）には依存せず、「役割（system prompt）・自己記述（AgentCard）・道具（ToolSet）」の 3 点を組み立てる責務のみを担います。

**設計の核心**: 有効ツール ID (`Set<MediaToolID>`) を唯一の入力とし、プロンプト・AgentCard・ToolSet の 3 要素を同じセットから生成することで整合性を保証します。

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

### Essentials

- <doc:GettingStarted>

### エージェント定義

- ``VisualizerAgent``
