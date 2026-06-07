// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "swift-media-agent",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "MediaStore", targets: ["MediaStore"]),
        .library(name: "MediaAgentTools", targets: ["MediaAgentTools"]),
        .library(name: "MediaAgent", targets: ["MediaAgent"]),
    ],
    dependencies: [
        // Tool プロトコル・JSONSchema・SystemPrompt（プロバイダー非依存の契約層）
        .package(url: "https://github.com/no-problem-dev/swift-llm-client.git", from: "3.4.0"),
        // AgentCard（A2A エージェントとしての自己記述）
        .package(url: "https://github.com/no-problem-dev/swift-a2a.git", from: "0.5.0"),
    ],
    targets: [
        // Layer 0: セッションスコープのメディア成果物ストア + 検証（UI / LLM / ネットワーク非依存）
        .target(
            name: "MediaStore"
        ),
        // Layer 1: メディア準備ツール群（生成・検索・取得検証・チャート・動画参照）
        .target(
            name: "MediaAgentTools",
            dependencies: [
                "MediaStore",
                .product(name: "LLMClient", package: "swift-llm-client"),
                .product(name: "LLMTool", package: "swift-llm-client"),
            ]
        ),
        // Layer 2: visualizer エージェントの組立（system prompt / AgentCard / ToolSet ファクトリ）
        .target(
            name: "MediaAgent",
            dependencies: [
                "MediaAgentTools",
                .product(name: "LLMClient", package: "swift-llm-client"),
                .product(name: "LLMTool", package: "swift-llm-client"),
                .product(name: "A2ACore", package: "swift-a2a"),
            ]
        ),
        .testTarget(
            name: "MediaStoreTests",
            dependencies: ["MediaStore"]
        ),
        .testTarget(
            name: "MediaAgentToolsTests",
            dependencies: ["MediaAgentTools", "MediaAgent"]
        ),
    ]
)
