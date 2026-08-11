import Foundation

/// Seam for every outbound request this package makes — image downloads, generation and search
/// APIs — so tests can substitute a mock without touching the network.
public protocol MediaHTTPClient: Sendable {
    /// Sends a request and returns the body and response whatever the status code.
    ///
    /// A non-2xx status is not an error at this level; callers that need one must check themselves.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Transport-level failure: a non-HTTP response, or a status outside 2xx carrying the first 300
/// bytes of the body for diagnosis.
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

/// Default implementation backed by `URLSession`.
///
/// `defaultTimeout` is applied only to requests still carrying `URLRequest`'s own default of 60
/// seconds. A request that deliberately asks for 60 is indistinguishable from one that never set a
/// timeout, and gets overwritten too.
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
    /// Sends a request and throws `MediaHTTPError.status` unless the response is 2xx.
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
    /// Browser-like User-Agent which, paired with a Referer, gets past most hotlink protection.
    ///
    /// It is not a guarantee: the same URL can still answer 403 later, which is exactly why the
    /// bytes are copied into the session directory rather than linked to.
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
