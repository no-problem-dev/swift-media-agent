# Getting Started with MediaAgent

Build the visualizer agent for the credentials you have, hand it to your executor, and turn the `media://` URLs it replies with into images.

## Installation

Add the package to the `dependencies` of your `Package.swift`:

```swift
.package(url: "https://github.com/no-problem-dev/swift-media-agent.git", from: "0.1.0")
```

Then add `MediaAgent` to your target. `MediaAgentTools` and `MediaStore` come with it, and you will import all three: the agent definition, the toolkit that satisfies it, and the store it writes into.

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "MediaAgent", package: "swift-media-agent")
    ]
)
```

## Basic usage

### Full configuration: cloud generation and web search

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

// Derive all three from availableToolIDs — the set the toolkit can actually serve.
let systemPrompt = VisualizerAgent.systemPrompt(tools: kit.availableToolIDs)
let toolSet = VisualizerAgent.toolSet(kit)
let agentCard = VisualizerAgent.agentCard(
    interfaceURL: "inprocess://visualizer",
    tools: kit.availableToolIDs
)
```

The Gemini key enables `generate_image`; the Serper key enables `search_images` and `search_videos`. A key that is absent, or an empty string, removes its tools from `availableToolIDs`, from the prompt and from the agent card together — nothing fails at run time because the model was told about a tool that was not there. `gl` and `hl` set the country and language of the search.

`interfaceURL` and `protocolBinding` describe where the agent is reachable, so they belong to the host: use an in-process URL when the agent runs inside your app, and its HTTP address when it is served remotely.

### Turning tools off

```swift
// Search only: no image generation of either kind.
let searchOnly = MediaToolID.allTools.subtracting([.generateImage, .generateUIImage])
let tools = kit.tools(enabled: searchOnly)
let prompt = VisualizerAgent.systemPrompt(tools: searchOnly)
// The prompt loses its generation route, and the tool descriptions stop
// suggesting generate_image as a fallback when a download fails.
```

Pass the same set everywhere. `MediaToolID.coreTools` — `save_image_url`, `save_video_reference`, `list_saved_media` — is always included whether you ask for it or not, because saving is how a result becomes a result and the final manifest is built from the listing.

### Adding on-device generation

`generate_ui_image` runs Apple's Image Playground model locally: free, offline, no key, but stylized output only, and it needs Apple Intelligence enabled on supported hardware with the image model downloaded. Check first and pass `nil` when the device cannot do it, so the tool never appears.

```swift
let onDevice: (any OnDeviceImageGenerating)? = await MainActor.run {
    PlaygroundImageGenerator.isSupported ? PlaygroundImageGenerator() : nil
}

let kit = MediaToolKit.gemini(
    store: store,
    geminiAPIKey: geminiKey,
    onDeviceImageGenerator: onDevice  // nil leaves generate_ui_image out entirely
)
```

### Minimal configuration: no keys at all

Without any external credentials the agent still validates and stores the URLs it is given, and still renders charts:

```swift
let kit = MediaToolKit(store: store)  // default URLSession HTTP client
let tools = kit.tools                 // save_image_url, save_video_reference,
                                      // list_saved_media, create_chart
```

The prompt built from this set tells the agent it has no search or generation tools and that its job is to validate and save the asset URLs in the task input.

### Using the reply

The agent replies with one line per verified asset, each quoting a `media://` URL, followed by `not found:` lines for anything it was asked for but could not verify. Those lines are the caller's cue to drop that asset rather than substitute one.

A `media://` URL is a reference, not a path, and nothing can load it directly. Resolve it at the point of display:

```swift
if let fileURL = MediaSessionStore.fileURL(forStable: stableURL) {
    // hand fileURL to the UI
}
```

Resolve late and store the `media://` form: on iOS the container path contains a UUID that changes when the app is reinstalled or rebuilt, so a file URL written to disk today will not open tomorrow.

The reply text itself is written in Japanese by default. Pass `language:` to change it — media URLs and alt text stay in English regardless:

```swift
let prompt = VisualizerAgent.systemPrompt(tools: kit.availableToolIDs, language: "English")
```

### Cleaning up

Media files are not evicted on their own. When a conversation is deleted, delete its directory:

```swift
MediaSessionStore.deleteSessionDirectory(sessionID: sessionID)
```
