# Getting Started with MediaStore

Create a session store, validate bytes before they reach disk, and resolve a stable reference back into a file URL.

## Installation

Add the package to the `dependencies` of your `Package.swift`:

```swift
.package(url: "https://github.com/no-problem-dev/swift-media-agent.git", from: "0.1.0")
```

Then add `MediaStore` to the target that needs it:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "MediaStore", package: "swift-media-agent")
    ]
)
```

`MediaStore` pulls in nothing beyond Foundation and ImageIO. Use it on its own when you want validated image storage without an agent involved.

## Basic usage

### Creating a store

One store per conversation session. Creating it creates its directory, which is why `init` can throw.

```swift
import MediaStore

// Writes to Application Support/MediaAgent/<sessionID>/
let store = try MediaSessionStore(sessionID: "session-\(conversationID)")

// Or choose the root yourself — a cache directory, or a temporary one in tests.
let store = try MediaSessionStore(
    rootDirectory: myDirectory,
    sessionID: "session-\(conversationID)"
)
```

Opening the same session ID again restores the previous state from `manifest.json`, including the hashes used to detect duplicates. Whichever root you pick, remember it: resolving a `media://` URL later needs the same one.

### Validating before saving

`ImageDataInspector.validate(_:policy:)` identifies the format from the leading magic bytes, then reads the pixel dimensions through ImageIO. The `Content-Type` header is not consulted at any point. Only bytes that pass should be handed to `save`; validation is what keeps HTML error pages, tracking pixels and banner strips out of the directory.

```swift
do {
    let validated = try ImageDataInspector.validate(imageData)

    let result = try await store.save(
        imageData,
        filenameHint: "product-photo",
        fileExtension: validated.format.fileExtension,
        kind: .fetchedImage,
        mimeType: validated.format.mimeType,
        width: validated.width,
        height: validated.height,
        alt: "A red sneaker on white background",
        sourceURL: "https://example.com/photo.jpg",
        pageURL: "https://example.com/product"
    )

    print(result.item.filename) // "product-photo.jpg"
    print(result.reused)        // true when these exact bytes were already stored
} catch let error as ImageValidationError {
    // Every case carries the numbers behind it: measured size and the limit missed,
    // byte count and the cap, or the first bytes of whatever arrived instead of an image.
    print(error.localizedDescription)
}
```

The default policy rejects anything over 10 MB, anything that is not PNG / JPEG / GIF / WebP / HEIC, anything ImageIO cannot decode, a short side below 200 px, and an aspect ratio beyond 4:1. Pass a policy to change those:

```swift
var policy = ImageValidationPolicy.default
policy.minShortSide = 64          // accept small thumbnails
policy.allowedFormats = [.png, .jpeg]
let validated = try ImageDataInspector.validate(imageData, policy: policy)
```

When `reused` comes back `true`, no file was written and the filename hint was ignored — the existing item is returned as-is. Two different URLs serving the same bytes therefore produce one file, not two.

### Using stable references

`media://` URLs are what you persist and what you hand to a model. File URLs are what you open, and only for as long as the process is running: on iOS the container path contains a UUID that changes on reinstall or rebuild, so a stored file URL stops resolving.

```swift
// Persist or send this.
let stableURL = store.stableURL(for: result.item)
// -> URL("media://session-uuid/product-photo.jpg")

// Resolve it immediately before display. Nothing can open a media:// URL directly.
if let fileURL = MediaSessionStore.fileURL(forStable: stableURL) {
    let image = UIImage(contentsOfFile: fileURL.path)
}
```

If the store was created with a custom `rootDirectory`, pass the same directory when resolving — the default is `Application Support/MediaAgent`:

```swift
let fileURL = MediaSessionStore.fileURL(forStable: stableURL, rootDirectory: myDirectory)
```

The call returns `nil` when the URL is not a `media://` URL, or when the session or filename part is missing.

### Cleaning up

Nothing is deleted automatically — no size cap, no expiry. Delete a session's directory when the conversation it belongs to goes away:

```swift
// Removes the media files and manifest.json together.
MediaSessionStore.deleteSessionDirectory(sessionID: conversationID)
```

Pass `rootDirectory:` here too if the store did not use the default root.

### Listing what is stored

```swift
let items = await store.allItems()   // in save order
for item in items {
    print("\(item.kind.rawValue): \(item.filename)")
}

// Or take a snapshot of the whole ledger; it is a copy and will not change under you.
let manifest = await store.currentManifest()
```
