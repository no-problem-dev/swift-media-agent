[English](./README.md) | 日本語

# swift-media-agent

AI エージェントが人に見せるための画像とチャートを用意する。検索するか生成し、中身を検証し、ディスクに保存するので、元の URL が死んだ後も参照が生き続ける。

## 概要

エージェントにレポートを作らせると、Web で見つけた画像 URL をそのまま返してくる。この URL は
死ぬ。hotlink 防止で弾かれ、署名付き URL は期限切れになり、ページは 404 になる。このパッケージは
その隙間を塞ぐ。画像は必ず取得または生成し、バイト列そのものから検証し、セッションディレクトリに
書き込む。エージェントが返すのは他人の URL ではなく、そのディレクトリを指す `media://` の安定参照。

検証は `Content-Type` ヘッダではなくマジックバイトと ImageIO のデコードで行う。HTML のエラー
ページやトラッキング用の 1px 画像は、保存される前に弾かれる。数値は画像生成モデルではなく決定的な
チャートレンダラに通す。画像モデルに数値を正しく描かせることはできないため。動画はサムネイルと
参照だけを持ち、動画本体はダウンロードしない。

同じバイト列は 1 度しか保存せず、名前が衝突したらファイル名に版を付ける。再起動後の状態は
セッションの `manifest.json` から復元できる。

能力は失敗せずに自分から消える。画像検索のキーが無ければ検索ツールはツールキットからも
プロンプトからも外れるので、エージェントが呼べないツールを知らされることはない。保存・動画参照・
一覧・チャートは常に使える。

## 使い方

```swift
import MediaAgent
import MediaAgentTools
import MediaStore

// 会話セッションごとに 1 つ。
let store = try MediaSessionStore(sessionID: sessionID)

// キーが無ければ検索ツールは自動的に外れる。
let kit = MediaToolKit.gemini(
    store: store,
    geminiAPIKey: geminiKey,
    serperAPIKey: serperKey,
    gl: "jp", hl: "ja"
)

// プロンプト・AgentCard・ToolSet は同じ有効ツール集合から導出するので、
// 「できること」の認識がずれない。
let prompt = VisualizerAgent.systemPrompt(tools: kit.availableToolIDs)
let toolSet = VisualizerAgent.toolSet(kit)
let card = VisualizerAgent.agentCard(
    interfaceURL: "inprocess://visualizer",
    tools: kit.availableToolIDs
)
```

`media://` URL はパスではなく参照。表示の直前に解決すること。コンテナのディレクトリは再インストール
で変わるので、file URL を保存しておくと次は解決できない:

```swift
if let fileURL = MediaSessionStore.fileURL(forStable: stableURL) {
    // fileURL を UI へ渡す
}
```

## ドキュメント

[API ドキュメント](https://no-problem-dev.github.io/swift-media-agent/documentation/mediaagent/)

## インストール

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/no-problem-dev/swift-media-agent.git", .upToNextMinor(from: "0.1.0"))
]
```

```swift
.target(name: "YourTarget", dependencies: [
    .product(name: "MediaAgent", package: "swift-media-agent"),      // プロンプト・AgentCard・ToolSet
    .product(name: "MediaAgentTools", package: "swift-media-agent"), // ツール本体
    .product(name: "MediaStore", package: "swift-media-agent"),      // 検証と保存だけ
])
```

`MediaStore` は Foundation と ImageIO 以外に依存しないので、エージェント抜きで「検証済み画像の
保管庫」としてだけ使うこともできる。

## コントリビュート

[CONTRIBUTING.md](./CONTRIBUTING.md) を参照。

## ライセンス

MIT。[LICENSE](./LICENSE) を参照。
