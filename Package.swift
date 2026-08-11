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
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0"),
        // Tool protocol, JSONSchema and SystemPrompt: the provider-independent contract layer.
        .package(url: "https://github.com/no-problem-dev/swift-llm-client.git", from: "4.0.0"),
        // AgentCard: how the agent describes itself to A2A callers.
        .package(url: "https://github.com/no-problem-dev/swift-a2a.git", from: "0.7.0"),
    ],
    targets: [
        // Stores media artifacts on disk per session and validates image bytes.
        // Depends on no UI, no LLM and no network.
        .target(
            name: "MediaStore"
        ),
        // The LLM-callable tools that produce media: generation, web search,
        // fetch-and-validate, chart rendering and video references.
        .target(
            name: "MediaAgentTools",
            dependencies: [
                "MediaStore",
                .product(name: "LLMClient", package: "swift-llm-client"),
                .product(name: "LLMTool", package: "swift-llm-client"),
            ]
        ),
        // Assembles the visualizer agent: system prompt, AgentCard and ToolSet
        // factories. Carries no execution machinery of its own.
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
