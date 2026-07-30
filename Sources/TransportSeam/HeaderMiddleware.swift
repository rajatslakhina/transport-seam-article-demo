import Foundation

/// Adds default fields to every outgoing request without overwriting anything
/// the caller set deliberately.
///
/// Worth noticing what this does *not* need: it never mentions `URLRequest`,
/// so it is the same code whichever transport is underneath.
public struct DefaultFieldsMiddleware: HTTPMiddleware {
    private let fields: HTTPFields

    public init(_ fields: HTTPFields) {
        self.fields = fields
    }

    public func intercept(_ request: HTTPRequest, next: HTTPResponder) async throws -> HTTPResponse {
        var request = request
        for field in fields {
            request.fields.setIfAbsent(field.name, field.value)
        }
        return try await next(request)
    }
}

/// Attaches a bearer token fetched at send time, so a refresh in flight is
/// picked up by the next attempt rather than baked in at composition time.
public struct BearerTokenMiddleware: HTTPMiddleware {
    private let token: @Sendable () async -> String?

    public init(token: @escaping @Sendable () async -> String?) {
        self.token = token
    }

    public func intercept(_ request: HTTPRequest, next: HTTPResponder) async throws -> HTTPResponse {
        var request = request
        if let token = await token() {
            request.fields.set("Authorization", to: "Bearer \(token)")
        }
        return try await next(request)
    }
}

/// One line of a request/response exchange, structured rather than stringly
/// typed so the demo app can render it and tests can assert on it.
public struct TransportLogEntry: Hashable, Sendable, Identifiable {
    public enum Outcome: Hashable, Sendable {
        case completed(HTTPStatus)
        case failed(String)
    }

    public let id: UUID
    public let attempt: Int
    public let method: HTTPMethod
    public let path: String
    public let outcome: Outcome

    public init(id: UUID = UUID(), attempt: Int, method: HTTPMethod, path: String, outcome: Outcome) {
        self.id = id
        self.attempt = attempt
        self.method = method
        self.path = path
        self.outcome = outcome
    }
}

/// Collects log entries. An actor because the demo app writes to it from a
/// detached task and reads it from the main actor.
public actor TransportLog {
    private var entries: [TransportLogEntry] = []

    public init() {}

    public func append(_ entry: TransportLogEntry) {
        entries.append(entry)
    }

    public func snapshot() -> [TransportLogEntry] {
        entries
    }

    public func clear() {
        entries.removeAll()
    }
}

/// Records every attempt, including the ones the retry layer above it makes.
///
/// Placed *inside* `RetryMiddleware` in the chain, it sees one entry per
/// physical send — which is exactly what makes a retry storm visible.
public struct LoggingMiddleware: HTTPMiddleware {
    private let log: TransportLog
    private let counter: AttemptCounter

    public init(log: TransportLog) {
        self.log = log
        self.counter = AttemptCounter()
    }

    public func intercept(_ request: HTTPRequest, next: HTTPResponder) async throws -> HTTPResponse {
        let attempt = await counter.next()
        let path = request.url.path.isEmpty ? "/" : request.url.path

        do {
            let response = try await next(request)
            await log.append(
                TransportLogEntry(
                    attempt: attempt,
                    method: request.method,
                    path: path,
                    outcome: .completed(response.status)
                )
            )
            return response
        } catch {
            await log.append(
                TransportLogEntry(
                    attempt: attempt,
                    method: request.method,
                    path: path,
                    outcome: .failed(String(describing: error))
                )
            )
            throw error
        }
    }
}

/// Monotonic attempt numbering shared by one `LoggingMiddleware` instance.
public actor AttemptCounter {
    private var value = 0

    public init() {}

    public func next() -> Int {
        value += 1
        return value
    }
}
