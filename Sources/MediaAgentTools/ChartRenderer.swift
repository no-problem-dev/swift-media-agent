import Foundation

/// Seam that turns a declarative chart specification into an image.
///
/// Charts go through deterministic rendering rather than an image model because a generated picture
/// gives no guarantee that a bar matches its number. The specification itself is kept in the ledger,
/// so the same chart can later be redrawn natively with Swift Charts.
public protocol ChartRendering: Sendable {
    /// Renders a Chart.js v4 configuration and returns the result as PNG bytes.
    ///
    /// - Parameters:
    ///   - chartConfigJSON: Chart.js v4 configuration as a JSON string.
    ///   - width: Chart width in points.
    ///   - height: Chart height in points.
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

/// Rendering through QuickChart.io, which is Chart.js-compatible, open source and self-hostable —
/// point `endpoint` at your own instance to keep chart data off a third party.
///
/// Malformed JSON is rejected locally before any request goes out.
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
