# ``MediaAgentTools``

The tools an LLM calls to obtain an image: generate one, search for one, render a chart, or reference a video — each result validated and written to the session directory before it is reported back.

## Overview

`MediaToolKit` assembles the tools. You give it a `MediaSessionStore` and whichever providers you have credentials for, and it hands back an array of `Tool` values ready to pass to an LLM client. Eight tools exist in total:

| Tool | What it does |
|---|---|
| `generate_image` | Generates an image with a cloud model and saves it. |
| `generate_ui_image` | Generates a decorative image on-device and saves it. |
| `search_images` | Returns candidate image URLs. Saves nothing. |
| `save_image_url` | Downloads a URL, validates the bytes, saves them. |
| `search_videos` | Returns candidate videos. Saves nothing. |
| `save_video_reference` | Verifies a YouTube video and saves its thumbnail. |
| `create_chart` | Renders a chart specification to a PNG and saves it. |
| `list_saved_media` | Lists everything saved this session, with its `media://` URLs. |

Every tool that produces bytes runs them through `MediaStore`'s validation before writing, and every tool that saves returns a `media://` URL rather than a path. A remote image URL is never a result: the bytes are re-hosted in the session directory, because hotlink protection, expiring signed URLs and later 404s all break a URL that was merely recorded.

```swift
import MediaAgent
import MediaAgentTools
import MediaStore

// One store per conversation session.
let store = try MediaSessionStore(sessionID: "session-\(UUID().uuidString)")

// Cloud generation via Gemini, image and video search via Serper.
let kit = MediaToolKit.gemini(
    store: store,
    geminiAPIKey: geminiKey,
    serperAPIKey: serperKey
)

// What this configuration can actually do.
let available = kit.availableToolIDs
// -> [.generateImage, .searchImages, .searchVideos, .saveImageURL,
//     .saveVideoReference, .createChart, .listSavedMedia]

// Tools and prompt come from the same set, so they cannot disagree.
let tools = kit.tools(enabled: available)
let prompt = VisualizerAgent.systemPrompt(tools: available)
```

### Which credential each capability needs

Missing credentials do not produce runtime failures. A tool whose provider was not configured is absent from ``MediaToolKit/availableToolIDs``, absent from `tools(enabled:)` even if you name it, and absent from the prompt built from the same set — the model is never told about a tool it cannot call.

- `generate_image` needs a Gemini API key, passed to ``MediaToolKit/gemini(store:geminiAPIKey:imageModel:serperAPIKey:gl:hl:onDeviceImageGenerator:)`` or supplied as your own ``ImageGenerating``. Without one, the toolkit has no cloud generation.
- `search_images` and `search_videos` need a Serper API key. `gemini(...)` treats a `nil` or empty key as absent, and both search tools drop out together — ``SerperMediaSearchProvider`` serves both.
- `generate_ui_image` needs no key, but needs an ``OnDeviceImageGenerating`` instance to be passed in. See below for when that is possible.
- `create_chart` needs no key. ``QuickChartRenderer`` is always configured, so charts always work.
- `save_image_url`, `save_video_reference` and `list_saved_media` need no key and cannot be switched off; ``MediaToolID/isCore`` is `true` for all three. Even a toolkit built with no providers at all can validate and store the URLs it was handed.

### Real subjects are searched for, invented ones are generated

`search_images` returns candidates only — title, URL, page, dimensions — and stores nothing. The model picks and calls `save_image_url`, which is where the download and the validation happen. This split exists so that a search result is judged on its bytes rather than on its listing.

`save_image_url` issues a GET with a browser `User-Agent` and a `Referer` (the page URL when one is given, otherwise the image's own origin), because many hosts refuse anything else. No HEAD request is made first: a HEAD probe adds a round trip and some servers answer it with 405, which would reject an image that is perfectly fetchable. A non-2xx response becomes ``MediaHTTPError/status(_:bodyPrefix:)`` carrying the first 300 bytes of the body.

Generation is for what does not exist yet — concept art, illustrations, header art. ``GeminiImageGenerator`` posts to the Gemini `generateContent` endpoint with image response modality; its ``GeminiImageGenerator/Preset`` catalogue selects the model, defaulting to `gemini-3.1-flash-image`, with a Pro preset for work that needs rendered text or higher resolution. Images returned by that API carry Google's invisible SynthID watermark. Requests take tens of seconds, so the generator uses a 180-second timeout.

### Numbers never go through an image model

`create_chart` takes a Chart.js v4 configuration as a JSON string and renders it deterministically — by default through ``QuickChartRenderer``, which posts to quickchart.io and gets a PNG back at twice the device pixel ratio on a white ground, 800×450 by default. An image model is not used and must not be: it cannot be trusted to draw a bar at the right height. Invalid JSON is caught before the request, as ``ChartRenderError/invalidConfigJSON(_:)``.

The configuration string itself is kept in the item's `chartSpec` field in the manifest, so the same chart can be redrawn later — natively with Swift Charts, at a different size, or in a different theme — without asking the model again. Swap in your own ``ChartRendering`` to render locally or against a self-hosted QuickChart instance.

### Videos are stored as a thumbnail and a link

`save_video_reference` calls YouTube's oEmbed endpoint, which needs no key. A successful lookup is the proof that the video exists — a removed or private video answers with a non-200, which becomes ``YouTubeOEmbedError/videoUnavailable(_:)``. The thumbnail is then downloaded (trying `maxresdefault`, then `hqdefault`, then the URL oEmbed reported) and saved with the video's URL and title attached. The video file itself is never downloaded; what the UI gets is an image and a link.

### On-device generation and Apple Intelligence

``PlaygroundImageGenerator`` uses Apple's Image Playground model: free, offline, no key, and stylized only — animation, illustration or sketch. It cannot do photorealism, accurate text or precise diagrams, so it is meant for decoration: backdrops, thumbnails, spot illustrations.

It requires iOS 18.4 / macOS 15.4 or later **and** Apple Intelligence enabled on supported hardware with the image model downloaded. Check ``PlaygroundImageGenerator/isSupported`` (main-actor isolated) and pass the generator only when it is `true`; otherwise leave it `nil` and the tool is never offered. If the device stops qualifying after the toolkit was built — the model is removed, the setting is turned off — generation throws ``OnDeviceImageError/notSupported`` at call time and the tool reports the failure back to the model rather than silently substituting the cloud generator.

### Failures are reported, not thrown

Tool bodies do not propagate errors to the LLM client. Anything thrown inside a tool is converted into an error result carrying that error's message, so the model can read what went wrong and act on it — try the next search candidate, or fall back to generation. A validation failure therefore reads as "Image 80x80 is too small (short side must be >= 200px)" in the transcript, and the run continues.

Generated images, rendered charts and video thumbnails are validated with the size and aspect-ratio limits relaxed, since those producers control their own output; the byte cap and the format whitelist still apply. Downloaded images are validated under the full policy you configured.

## Topics

### Assembling the tools

- ``MediaToolKit``
- ``MediaToolID``

### Cloud image generation

- ``ImageGenerating``
- ``GeminiImageGenerator``
- ``ImageGeneratorError``

### On-device image generation

- ``OnDeviceImageGenerating``
- ``PlaygroundImageGenerator``
- ``OnDeviceImageError``

### Image search

- ``ImageSearchProvider``
- ``ImageSearchHit``
- ``SerperMediaSearchProvider``

### Video search

- ``VideoSearchProvider``
- ``VideoSearchHit``

### Chart rendering

- ``ChartRendering``
- ``QuickChartRenderer``
- ``ChartRenderError``

### YouTube video references

- ``YouTubeOEmbed``
- ``VideoEmbedInfo``
- ``YouTubeOEmbedError``

### HTTP

- ``MediaHTTPClient``
- ``URLSessionMediaHTTPClient``
- ``MediaHTTPError``
