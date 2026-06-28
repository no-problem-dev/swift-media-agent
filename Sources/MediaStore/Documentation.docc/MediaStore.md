# ``MediaStore``

セッションスコープのメディア成果物ストア。AI エージェントが生成・取得した画像を検証・保存・台帳管理する。

## Overview

`MediaStore` は UI レイヤーや LLM クライアントに依存しない純粋なストレージ層。AI エージェントが生成または取得したメディア（画像・チャート・動画サムネイル）を、セッション単位でファイルシステムに保存し `manifest.json` で台帳化する。

主な特徴:

- **SHA-256 重複排除**: 同一バイト列を 2 度保存しない
- **コンテナ非依存の安定 URL**: `media://<sessionID>/<filename>` で参照し、iOS の再インストール後も解決可能
- **べき等**: 再起動後も `manifest.json` から状態を復元する
- **バイト列検証**: `ImageDataInspector` でマジックバイト・寸法・アスペクト比を検証してから保存する

```swift
import MediaStore

// セッションストアを作成
let store = try MediaSessionStore(sessionID: "session-\(UUID().uuidString)")

// 画像を検証して保存
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

// 安定 URL で参照（コンテナパスに依存しない）
let stableURL = store.stableURL(for: result.item)
// → "media://session-uuid/hero-image.jpg"
```

## Topics

### はじめに

- <doc:GettingStarted>

### ストア

- ``MediaSessionStore``
- ``MediaItem``
- ``MediaManifest``
- ``MediaKind``
- ``MediaStoreError``

### 画像検証

- ``ImageDataInspector``
- ``ImageValidationPolicy``
- ``ValidatedImage``
- ``ImageByteFormat``
- ``ImageValidationError``
