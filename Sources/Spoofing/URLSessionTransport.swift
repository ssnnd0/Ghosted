// The iOS-side performer for `GhostedCore.HTTPTransport`. iOS-only.
//
// GhostedCore is deliberately networking-free so it compiles on Linux and Windows. This is
// the one place a real socket exists, which keeps `URLSession` out of the portable target and
// keeps every route provider unit-testable against a stub transport.

#if os(iOS)
import Foundation
import GhostedCore
// On Apple platforms `URLSession` is part of Foundation, but corelibs-foundation puts it in a
// separate module. The conditional import keeps this file compiling for the type-check harness
// (and for any future non-Apple host) without changing what iOS sees.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `URLSession`-backed `HTTPTransport`.
struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// A session with the timeout that suits interactive route planning.
    ///
    /// `URLSession.shared` has a 60 s request timeout and a 7-day resource timeout, both far
    /// too patient: a hung routing request should surface as an error the user can act on
    /// within a few seconds, not leave the UI spinning.
    static func makeDefault(timeout: TimeInterval = 15) -> URLSessionTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.waitsForConnectivity = false   // fail fast offline rather than queue forever
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSessionTransport(session: URLSession(configuration: configuration))
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let url = URL(string: request.url) else {
            // A malformed URL means a misconfigured base URL in code — a programmer error, not
            // a network condition, so it surfaces as a routing failure the UI can display.
            throw RouterError.providerFailure(
                "The routing base URL is not a valid URL: \(request.url)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }

        do {
            let (data, response) = try await session.data(for: urlRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return HTTPResponse(status: status, body: data)
        } catch let error as URLError {
            throw RouterError.providerFailure(Self.describe(error))
        }
    }

    /// Turns a `URLError` into something a person can act on. The raw enum is useless in a UI —
    /// "-1009" tells nobody anything.
    private static func describe(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet: return "No internet connection."
        case .timedOut: return "The routing server did not respond in time."
        case .cannotFindHost, .cannotConnectToHost: return "Could not reach the routing server."
        case .appTransportSecurityRequiresSecureConnection: return "The routing URL must use https."
        case .networkConnectionLost: return "The connection to the routing server dropped."
        case .cancelled: return "The route request was cancelled."
        default: return "Routing request failed (\(error.code)): \(error.localizedDescription)"
        }
    }
}
#endif