# ``MediaStore``

Checks image bytes, keeps the ones worth keeping on disk under a session, and records what it kept in a ledger that survives a restart.

## Overview

`MediaStore` is the storage half of the package. It takes bytes, decides whether they are a usable image, writes the ones that pass into a per-session directory, and records what it wrote. It depends on Foundation and ImageIO only — no network, no UI, no LLM — so it is usable on its own anywhere validated image storage is wanted.

### Where the files go

A store writes into `<root>/<sessionID>/`. The root defaults to `Application Support/MediaAgent`; pass `rootDirectory:` to put it elsewhere, such as a cache directory or a temporary directory in tests. Each saved item becomes one file, named from its `filenameHint`, and the same directory holds `manifest.json` listing every item in the session.

Nothing is evicted on its own: there is no size cap, no age limit and no cleanup when the store is released. Files stay until something removes them. The one API that removes them is ``MediaSessionStore/deleteSessionDirectory(sessionID:rootDirectory:)``, and it deletes the entire session directory, manifest included. There is no per-item delete, and the call ignores failure. Call it when the conversation the session belongs to is deleted; otherwise the directory outlives the process.

Opening a store on an existing session ID reads `manifest.json` back and re-hashes the files it lists, so a relaunch continues that session instead of starting a new one.

### What is allowed to be saved

``ImageDataInspector/validate(_:policy:)`` decides. Format is identified from the leading magic bytes — PNG, JPEG, GIF, WebP or HEIC — and never from a `Content-Type` header, because servers misreport it routinely and an error page commonly arrives as HTTP 200 with `text/html`. Bytes that pass the sniff must then decode: pixel dimensions are read through ImageIO's `CGImageSource`, which reads the image header rather than the full image.

Under the default policy, bytes are rejected when they exceed 10 MB, are not one of those five formats, cannot be decoded, have a short side under 200 px, or have a long-to-short side ratio above 4:1. The last two throw out icons, tracking pixels, spacers and banner strips. Pass an ``ImageValidationPolicy`` with different limits to change any of them.

Failure throws a typed ``ImageValidationError`` — `validate` is declared `throws(ImageValidationError)`, so a caller can switch over the cases exhaustively. Every case carries the numbers behind it: the measured dimensions and the limit that was missed, the byte count and the cap, and for `notAnImage` the first 64 bytes of the body decoded as text, which is usually enough to identify the error page that came back instead of an image. Nothing is written when validation fails.

### Stable references

`stableURL(for:)` returns `media://<sessionID>/<filename>`. That is a reference, not a location — no image loader can open it. Turn it into something loadable with ``MediaSessionStore/fileURL(forStable:rootDirectory:)``, immediately before use.

The distinction matters because absolute file URLs go stale. On iOS the app container path contains a UUID that changes when the app is reinstalled or rebuilt, so a file URL that was persisted — or handed to a model and quoted back in a later turn — points at a directory that no longer exists. Persist and pass `media://` URLs; resolve them at the point of display. `fileURL(for:)` is correct for immediate use and wrong to store.

Resolution must be given the same root the store was created with. `fileURL(forStable:)` defaults to `Application Support/MediaAgent`, so a store built with a custom `rootDirectory` has to be resolved with that same directory. The call returns `nil` for a URL that is not `media://` or that is missing the session or filename part.

### Saving is idempotent

Every save hashes its bytes with SHA-256 first. If those exact bytes are already in the session, no file is written and the existing item comes back with `reused == true`; the filename hint is ignored in that case, so the same picture fetched from two different URLs stays one file. Otherwise the hint is slugified — lowercased, runs of non-ASCII-alphanumeric characters become `-`, trimmed to 60 characters — and a name that collides gets `-2`, `-3` and so on rather than overwriting. A hint containing no ASCII letters or digits, Japanese text for instance, slugs down to `media`, then `media-2`.

Files are written atomically. A failed write throws ``MediaStoreError/writeFailed(_:)`` with the path, and a directory that cannot be created throws ``MediaStoreError/directoryCreationFailed(_:)`` from `init`. The manifest is rewritten atomically after each save that wrote a file.

```swift
import MediaStore

// One store per conversation session.
let store = try MediaSessionStore(sessionID: "session-\(UUID().uuidString)")

// Validate first: nothing reaches disk until the bytes pass.
let validated = try ImageDataInspector.validate(imageData)
let result = try await store.save(
    imageData,
    filenameHint: "hero-image",
    fileExtension: validated.format.fileExtension,
    kind: .fetchedImage,
    mimeType: validated.format.mimeType,
    width: validated.width,
    height: validated.height,
    alt: "Tokyo Tower at sunset"
)

// Reference it by a URL that does not depend on the container path.
let stableURL = store.stableURL(for: result.item)
// -> "media://session-uuid/hero-image.jpg"
```

## Topics

### Essentials

- <doc:GettingStarted>

### Storing media

- ``MediaSessionStore``
- ``MediaItem``
- ``MediaManifest``
- ``MediaKind``
- ``MediaStoreError``

### Validating image bytes

- ``ImageDataInspector``
- ``ImageValidationPolicy``
- ``ValidatedImage``
- ``ImageByteFormat``
- ``ImageValidationError``
