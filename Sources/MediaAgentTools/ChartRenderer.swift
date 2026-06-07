import Foundation

/// チャート仕様（Chart.js config JSON）を画像にレンダリングするシーム。
///
/// データの数値正確性が要るチャートを画像生成 AI に描かせるのは非推奨
/// （数値とバーの対応が保証されない）ため、宣言仕様 → 決定論的レンダリングを使う。
/// 仕様 JSON 自体も manifest に保持し、将来のネイティブ（Swift Charts）描画へ移行可能にする。
public protocol ChartRendering: Sendable {
    func render(chartConfigJSON: String, width: Int, height: Int) async throws -> Data
}

public enum ChartRenderError: Error, Sendable, LocalizedError {
    case invalidConfigJSON(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfigJSON(let detail): "chart_config is not valid JSON: \(detail)"
        }
    }
}

/// QuickChart.io（Chart.js 互換、OSS・セルフホスト可）によるレンダリング。
public struct QuickChartRenderer: ChartRendering {
    let http: any MediaHTTPClient
    let endpoint: URL

    public init(
        http: any MediaHTTPClient = URLSessionMediaHTTPClient(defaultTimeout: 30),
        endpoint: URL = URL(string: "https://quickchart.io/chart")!
    ) {
        self.http = http
        self.endpoint = endpoint
    }

    public func render(chartConfigJSON: String, width: Int, height: Int) async throws -> Data {
        let config: Any
        do {
            config = try JSONSerialization.jsonObject(with: Data(chartConfigJSON.utf8))
        } catch {
            throw ChartRenderError.invalidConfigJSON(error.localizedDescription)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "chart": config,
            "width": width,
            "height": height,
            "format": "png",
            "devicePixelRatio": 2,
            "backgroundColor": "white",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await http.sendExpectingSuccess(request)
        return data
    }
}
