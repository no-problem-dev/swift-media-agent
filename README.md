English | [日本語](./README.ja.md)

# swift-media-agent

Gets an AI agent the images and charts it needs to show someone — found or generated, checked, and saved on disk so the references keep working after the original URLs stop.

## Overview

Ask an agent for a report and it will happily hand back image URLs it found on the web.
Those URLs break: hotlink protection blocks them, signed URLs expire, pages 404. This
package closes that gap. Every image is fetched or generated, verified from its own bytes,
and written into a session directory; what the agent hands back is a stable `media://`
reference into that directory rather than someone else's URL.

Verification is by magic bytes and an ImageIO decode, not by the `Content-Type` header, so
an HTML error page or a tracking pixel is rejected before it is ever saved. Numbers go
through a deterministic chart renderer instead of an image model, because an image model
cannot be trusted to draw a value correctly. Video is kept as a thumbnail and a reference
only — the video itself is never downloaded.

Identical bytes are stored once, filenames are versioned on collision, and the session's
`manifest.json` is enough to reconstruct the state after a restart.

Capabilities switch themselves off rather than failing: with no image-search key the search
tools are absent from the toolkit and from the prompt, so the agent is never told about a
tool it cannot call. Saving, video references, listing and charts always work.

## Usage

```swift
import MediaAgent
import MediaAgentTools
import MediaStore

// One store per conversation session.
let store = try MediaSessionStore(sessionID: sessionID)

// Search tools drop out automatically when the key is absent.
let kit = MediaToolKit.gemini(
    store: store,
    geminiAPIKey: geminiKey,
    serperAPIKey: serperKey,
    gl: "jp", hl: "ja"
)

// Prompt, agent card and tool set all derive from the same enabled set,
// so they cannot disagree about what the agent can do.
let prompt = VisualizerAgent.systemPrompt(tools: kit.availableToolIDs)
let toolSet = VisualizerAgent.toolSet(kit)
let card = VisualizerAgent.agentCard(
    interfaceURL: "inprocess://visualizer",
    tools: kit.availableToolIDs
)
```

A `media://` URL is a reference, not a path. Resolve it immediately before display —
the container directory changes between installs, so a stored file URL will not survive one:

```swift
if let fileURL = MediaSessionStore.fileURL(forStable: stableURL) {
    // hand fileURL to the UI
}
```

## Documentation

[API documentation](https://no-problem-dev.github.io/swift-media-agent/documentation/mediaagent/)

## Installation

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/no-problem-dev/swift-media-agent.git", .upToNextMinor(from: "0.1.0"))
]
```

```swift
.target(name: "YourTarget", dependencies: [
    .product(name: "MediaAgent", package: "swift-media-agent"),      // prompt, agent card, tool set
    .product(name: "MediaAgentTools", package: "swift-media-agent"), // the tools themselves
    .product(name: "MediaStore", package: "swift-media-agent"),      // validation and storage only
])
```

`MediaStore` depends on nothing but Foundation and ImageIO, so it can be used on its own
wherever validated image storage is needed without an agent involved.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md).

## License

MIT. See [LICENSE](./LICENSE).
