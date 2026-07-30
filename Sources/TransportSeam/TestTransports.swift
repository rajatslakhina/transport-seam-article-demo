import Foundation

/// A transport that replays a fixed script and records what it was asked to do.
///
/// This is the payoff of a one-method protocol: the whole "network layer" in a
/// test is forty lines with no URL loading system, no `URLProtocol` subclass and
/// no port binding.
public actor ScriptedTransport: HTTPTransport {
    public enum Step: Sendable {
        case respond(HTTPResponse)
        case fail(TransportError)
    }

    private let script: [Step]
    private let repeatsLastStep: Bool
    private var index = 0
    private var received: [HTTPRequest] = []

    public init(script: [Step], repeatsLastStep: Bool = true) {
        self.script = script
        self.repeatsLastStep = repeatsLastStep
    }

    public init(responses: [HTTPResponse], repeatsLastStep: Bool = true) {
        self.init(script: responses.map { .respond($0) }, repeatsLastStep: repeatsLastStep)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        received.append(request)

        guard !script.isEmpty else {
            throw TransportError.malformedResponse(reason: "ScriptedTransport was given an empty script")
        }

        let step: Step
        if index < script.count {
            step = script[index]
            index += 1
        } else if repeatsLastStep, let last = script.last {
            step = last
        } else {
            throw TransportError.malformedResponse(
                reason: "ScriptedTransport ran out of steps after \(script.count) sends"
            )
        }

        switch step {
        case .respond(let response):
            return response
        case .fail(let error):
            throw error
        }
    }

    /// Every request the transport was handed, including retried duplicates.
    public func recordedRequests() -> [HTTPRequest] {
        received
    }

    public func sendCount() -> Int {
        received.count
    }
}

/// A hand-rolled in-process server. Not a mock of `URLSession` — a genuinely
/// different implementation of the same protocol, which is the point: the
/// feature code above it cannot tell the difference.
public struct LoopbackTransport: HTTPTransport {
    public struct Route: Hashable, Sendable {
        public let method: HTTPMethod
        public let path: String

        public init(method: HTTPMethod, path: String) {
            self.method = method
            self.path = path
        }
    }

    private let routes: [Route: HTTPResponse]
    private let notFoundBody: Data

    public init(routes: [Route: HTTPResponse]) {
        self.routes = routes
        self.notFoundBody = Data("{\"error\":\"no route\"}".utf8)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let path = request.url.path.isEmpty ? "/" : request.url.path
        let route = Route(method: request.method, path: path)

        guard let response = routes[route] else {
            return HTTPResponse(
                status: HTTPStatus(404),
                fields: [("Content-Type", "application/json")],
                body: notFoundBody
            )
        }

        return response
    }
}

/// Fails the first `failures` sends with a transient status, then serves the
/// real response. Used by the demo app to make the retry ladder visible.
public actor FlakyTransport: HTTPTransport {
    private let base: any HTTPTransport
    private let failures: Int
    private let transientStatus: HTTPStatus
    private var sends = 0

    public init(base: any HTTPTransport, failures: Int, transientStatus: HTTPStatus = .internalServerError) {
        self.base = base
        self.failures = max(0, failures)
        self.transientStatus = transientStatus
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        sends += 1

        if sends <= failures {
            return HTTPResponse(
                status: transientStatus,
                fields: [("Content-Type", "application/json")],
                body: Data("{\"error\":\"upstream unavailable\"}".utf8)
            )
        }

        return try await base.send(request)
    }
}
