import Foundation

/// The seam.
///
/// Everything above this line speaks `HTTPRequest`/`HTTPResponse`. Everything
/// below it is an implementation detail — `URLSession` today, whatever the
/// Swift Networking Workgroup ships tomorrow, a fixture in tests.
///
/// One method, two currency types, no associated types. It is deliberately the
/// smallest surface that a feature module can be written against, because every
/// extra requirement here is another thing a future transport has to satisfy.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// A single request/response step, used to chain middleware.
public typealias HTTPResponder = @Sendable (HTTPRequest) async throws -> HTTPResponse

/// Failures that belong to the seam itself rather than to any one transport.
///
/// A concrete transport is expected to translate its own error vocabulary
/// (`URLError`, an `NIO` channel error, a gRPC status) into one of these, so
/// call sites never learn which stack is underneath.
public enum TransportError: Error, Hashable, Sendable {
    /// The transport could not reach the server at all.
    case unreachable(reason: String)
    /// The transport reached the server but the exchange did not complete.
    case interrupted(reason: String)
    /// The response arrived but could not be interpreted as HTTP.
    case malformedResponse(reason: String)
    /// The request was cancelled by structured concurrency.
    case cancelled
}

/// A response whose status is not a success, surfaced as an error by callers
/// that want `try` to mean "I got a usable payload".
public struct HTTPStatusError: Error, Hashable, Sendable {
    public let response: HTTPResponse

    public init(response: HTTPResponse) {
        self.response = response
    }

    public var status: HTTPStatus { response.status }
}

// MARK: - Middleware

/// Cross-cutting behaviour that wraps a transport without knowing which one it is.
///
/// Retries, auth headers, logging and tracing all live here, which is why they
/// survive a transport swap untouched.
public protocol HTTPMiddleware: Sendable {
    func intercept(_ request: HTTPRequest, next: HTTPResponder) async throws -> HTTPResponse
}

/// Composes middleware around a base transport. The first element of
/// `middleware` is the outermost layer — it sees the request first and the
/// response last.
public struct MiddlewareTransport: HTTPTransport {
    private let base: any HTTPTransport
    private let middleware: [any HTTPMiddleware]

    public init(base: any HTTPTransport, middleware: [any HTTPMiddleware]) {
        self.base = base
        self.middleware = middleware
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let base = self.base
        var responder: HTTPResponder = { try await base.send($0) }

        for layer in middleware.reversed() {
            let downstream = responder
            responder = { try await layer.intercept($0, next: downstream) }
        }

        return try await responder(request)
    }
}

public extension HTTPTransport {
    /// Sugar so a composition root reads top-down in the order requests travel.
    func wrapped(in middleware: [any HTTPMiddleware]) -> MiddlewareTransport {
        MiddlewareTransport(base: self, middleware: middleware)
    }
}
