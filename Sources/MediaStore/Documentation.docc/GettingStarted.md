# Getting Started with MediaStore

セッションストアのセットアップから画像の保存・安定 URL 解決までの基本的な使い方。

## インストール

`Package.swift` の `dependencies` に追加する:

```swift
.package(url: "https://github.com/no-problem-dev/swift-media-agent.git", from: "0.1.0")
```

ターゲットの `dependencies` に `MediaStore` を追加する:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "MediaStore", package: "swift-media-agent")
    ]
)
```

## 基本的な使い方

### ストアの作成

```swift
import MediaStore

// Application Support/MediaAgent/<sessionID>/ に保存（デフォルト）
let store = try MediaSessionStore(sessionID: "session-\(conversationID)")

// カスタムルートディレクトリを指定する場合
let store = try MediaSessionStore(
    rootDirectory: myDirectory,
    sessionID: "session-\(conversationID)"
)
```

### 画像を検証してから保存する

`ImageDataInspector.validate(_:policy:)` でマジックバイト・寸法・アスペクト比を検証した後にのみ保存する。
HTML エラーページやトラッカー画像の混入を防ぐための重要なゲート。

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
    print(result.reused)        // 同一バイトが既存ならば true
} catch let error as ImageValidationError {
    // format 不一致・サイズ過小・アスペクト比超過などを個別に処理
    print(error.localizedDescription)
}
```

### 安定 URL を使う

iOS ではアプリの再インストールでコンテナパスが変わるため、LLM への参照渡しや永続化には `media://` スキームを使う。

```swift
// 保存時に安定 URL を取得
let stableURL = store.stableURL(for: result.item)
// → URL("media://session-uuid/product-photo.jpg")

// 描画直前に現在のコンテナパスへ解決
if let fileURL = MediaSessionStore.fileURL(forStable: stableURL) {
    let image = UIImage(contentsOfFile: fileURL.path)
}
```

### セッション終了時のクリーンアップ

```swift
// セッションディレクトリ（ファイル群 + manifest.json）を丸ごと削除
MediaSessionStore.deleteSessionDirectory(sessionID: conversationID)
```

### 保存済みアイテムの一覧取得

```swift
let items = await store.allItems()
for item in items {
    print("\(item.kind.rawValue): \(item.filename)")
}
```
