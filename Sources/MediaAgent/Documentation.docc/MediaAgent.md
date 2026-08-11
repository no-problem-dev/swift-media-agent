# ``MediaAgent``

The visualizer agent's definition — system prompt, A2A agent card and tool set — all derived from one set of enabled tool IDs.

## Overview

`MediaAgent` provides a single namespace type, ``VisualizerAgent``. It describes an agent that sources the media a UI needs: it finds or generates each asset, validates it, saves it, and replies with a manifest of `media://` URLs the caller can use directly.

It carries no execution machinery. There is no LLM client here, no A2A executor, no run loop — only the three things a host needs in order to run this agent inside whatever runner it already has: the role (a `SystemPrompt`), the self-description (an `AgentCard`), and the tools (a `ToolSet`).

All three are built from the same input: a `Set<MediaToolID>`. Pass your toolkit's `availableToolIDs` to each of them and the prompt cannot mention a tool that is not in the tool set, and the agent card cannot advertise a skill the agent cannot perform. A configuration without a search key produces a prompt that says nothing about searching and a card that lists no search skill.

```swift
import MediaAgent
import MediaAgentTools
import MediaStore

// 1. One store per conversation session.
let store = try MediaSessionStore(sessionID: sessionID)

// 2. A toolkit for the credentials you have.
let kit = MediaToolKit.gemini(
    store: store,
    geminiAPIKey: geminiKey,
    serperAPIKey: serperKey
)

// 3. Prompt, card and tools, all from the same set.
let tools = kit.tools                                     // [any Tool]
let prompt = VisualizerAgent.systemPrompt(tools: kit.availableToolIDs)
let card = VisualizerAgent.agentCard(
    interfaceURL: "inprocess://visualizer",
    tools: kit.availableToolIDs
)
let toolSet = VisualizerAgent.toolSet(kit)                // for your agent executor
```

### What the prompt tells the agent to do

Routing is by what the asset depicts, not by how the request was phrased. Anything plausibly already published — people, products, places, screenshots, diagrams from documentation — is searched for and then downloaded and validated. Visuals that do not exist yet — concept art, header art — are generated. Numeric data goes to the chart tool, which renders a specification deterministically, and the prompt forbids inventing values. Talks and demos become video references verified through oEmbed. Only the routes whose tools are enabled appear in the prompt.

Two rules run through all of it. Remote URLs are not deliverables: an asset counts only once its bytes have been validated and saved, and the reply quotes the `media://` URL that came back. And nothing unverified may be mentioned — an entity the tools did not confirm this session is reported on a `not found:` line so the caller can omit it, never replaced with a plausible guess.

The reply itself is a manifest, one line per verified asset, in the form `- kind | media URL | alt/description | suggested placement`. `systemPrompt(tools:language:)` writes that instruction in Japanese by default; pass `language:` for anything else. The `media://` URLs it returns are references, not paths — resolve each one with `MediaSessionStore.fileURL(forStable:)` immediately before displaying it, because a container path stored today stops resolving after a reinstall.

### The rest of the package

- `MediaAgent` — this module. Prompt, agent card and tool set for the visualizer agent.
- `MediaAgentTools` — the tools themselves. `MediaToolKit` assembles image generation (cloud and on-device), image and video search, chart rendering and video references; `MediaToolID` selects which of them are in play.
- `MediaStore` — validation and storage. `MediaSessionStore` writes validated bytes into a session directory, deduplicates by SHA-256, records everything in `manifest.json`, and issues the `media://` URLs.

## Topics

### Essentials

- <doc:GettingStarted>

### Agent definition

- ``VisualizerAgent``
