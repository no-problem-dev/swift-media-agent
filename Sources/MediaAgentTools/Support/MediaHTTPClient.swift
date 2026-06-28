import Foundation

/// メディア取得・API 呼び出しの HTTP シーム。テストではモックに差し替える。
public protocol MediaHTTPClient: Sendable {
    /// URLRequest を送信し、ステータスコードに関わらず (Data, HTTPURLResponse) を返す。
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// メディア HTTP クライアントが返すエラー。
public enum MediaHTTPError: Error, Sendable, LocalizedError {
    case invalidResponse
    case status(Int, bodyPrefix: String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "Invalid (non-HTTP) response"
        case .status(let code, let prefix): "HTTP \(code): \(prefix)"
        }
    }
}

/// `MediaHTTPClient` の URLSession ベースの標準実装。
///
/// `session` と `defaultTimeout` を注入してテストや特殊ネットワーク構成に対応できる。
public struct URLSessionMediaHTTPClient: MediaHTTPClient {
    public let session: URLSession
    public let defaultTimeout: TimeInterval

    public init(session: URLSession = .shared, defaultTimeout: TimeInterval = 60) {
        self.session = session
        self.defaultTimeout = defaultTimeout
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        if request.timeoutInterval == 60 { request.timeoutInterval = defaultTimeout }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MediaHTTPError.invalidResponse }
        return (data, http)
    }
}

extension MediaHTTPClient {
    /// 2xx 以外をエラーにする送信。
    func sendExpectingSuccess(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            let prefix = String(data: data.prefix(300), encoding: .utf8) ?? "<binary>"
            throw MediaHTTPError.status(response.statusCode, bodyPrefix: prefix)
        }
        return (data, response)
    }
}

enum BrowserHeaders {
    /// hotlink 防止対策: 検証・取得時はブラウザ相当の UA と Referer を付ける。
    /// それでも表示時に 403 になり得るため、バイトを保存（リホスト）するのが本筋。
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    static func imageRequest(url: URL, referer: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("image/avif,image/webp,image/png,image/jpeg,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        } else if let host = url.host, let scheme = url.scheme {
            request.setValue("\(scheme)://\(host)/", forHTTPHeaderField: "Referer")
        }
        return request
    }
}
