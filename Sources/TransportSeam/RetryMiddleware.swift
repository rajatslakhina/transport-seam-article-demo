import Foundation

/// Something that can wait. Injected so retry behaviour is unit-testable in
/// microseconds instead of in wall-clock seconds.
public protocol RetryClock: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct SystemRetryClock: RetryClock {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// Supplies the multiplier applied to each computed backoff delay. Injected for
/// the same reason as the clock: jitter that cannot be pinned cannot be tested.
public protocol JitterSource: Sendable {
    /// Returns a factor in `0...1`.
    func nextFactor() -> Double
}

/// Full jitter, as described in the AWS backoff literature: sleep a random
/// amount up to the computed ceiling, so a thundering herd de-synchronises
/// instead of retrying in lockstep.
public struct FullJitter: JitterSource {
    public init() {}

    public func nextFactor() -> Double {
        Double.random(in: 0...1)
    }
}

/// Always returns the same factor. `FixedJitter(1)` gives pure exponential
/// backoff, which is what the tests assert against.
public struct FixedJitter: JitterSource {
    private let factor: Double

    public init(_ factor: Double) {
        self.factor = min(max(factor, 0), 1)
    }

    public func nextFactor() -> Double { factor }
}

public struct RetryPolicy: Sendable {
    /// Total attempts including the first. `1` disables retrying.
    public let maxAttempts: Int
    public let baseDelay: Duration
    public let multiplier: Double
    public let maxDelay: Duration
    /// Honour a `Retry-After` header when the server sends one.
    public let respectsRetryAfter: Bool

    public init(
        maxAttempts: Int = 3,
        baseDelay: Duration = .milliseconds(200),
        multiplier: Double = 2,
        maxDelay: Duration = .seconds(8),
        respectsRetryAfter: Bool = true
    ) {
        // A policy that says "zero attempts" is a configuration bug, not an
        // instruction to never send the request.
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
        self.multiplier = max(1, multiplier)
        self.maxDelay = maxDelay
        self.respectsRetryAfter = respectsRetryAfter
    }

    /// Backoff before the retry that follows `attempt`, where the first send is
    /// attempt 1.
    public func delay(afterAttempt attempt: Int, jitterFactor: Double) -> Duration {
        guard attempt >= 1 else { return .zero }

        let scaled = RetryPolicy.seconds(of: baseDelay) * pow(multiplier, Double(attempt - 1))
        let capped = min(scaled, RetryPolicy.seconds(of: maxDelay))
        let factor = min(max(jitterFactor, 0), 1)
        return .seconds(capped * factor)
    }

    static func seconds(of duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// Retries transient failures with capped exponential backoff and jitter.
///
/// Two rules here are load-bearing.
///
/// 1. A request that is not safely repeatable is never re-sent, however
///    transient the failure looked. A duplicated `GET` is free; a duplicated
///    `POST /payments` is a support ticket.
/// 2. Running out of attempts does not invent a new error. The caller gets the
///    last real response or the last real error, because a synthetic
///    `retriesExhausted` throws away the only diagnosis anyone wanted.
public struct RetryMiddleware: HTTPMiddleware {
    private let policy: RetryPolicy
    private let clock: any RetryClock
    private let jitter: any JitterSource

    public init(
        policy: RetryPolicy = RetryPolicy(),
        clock: any RetryClock = SystemRetryClock(),
        jitter: any JitterSource = FullJitter()
    ) {
        self.policy = policy
        self.clock = clock
        self.jitter = jitter
    }

    public func intercept(_ request: HTTPRequest, next: HTTPResponder) async throws -> HTTPResponse {
        var attempt = 1

        while true {
            do {
                let response = try await next(request)

                guard response.status.isTransient,
                      request.isSafelyRepeatable,
                      attempt < policy.maxAttempts else {
                    return response
                }

                try await wait(after: attempt, retryAfter: response.fields.first("Retry-After"))
            } catch let error as TransportError {
                guard isRetryable(error),
                      request.isSafelyRepeatable,
                      attempt < policy.maxAttempts else {
                    throw error
                }

                try await wait(after: attempt, retryAfter: nil)
            }

            attempt += 1
        }
    }

    private func isRetryable(_ error: TransportError) -> Bool {
        switch error {
        case .unreachable, .interrupted:
            return true
        case .malformedResponse, .cancelled:
            return false
        }
    }

    private func wait(after attempt: Int, retryAfter header: String?) async throws {
        if policy.respectsRetryAfter,
           let header,
           let seconds = Double(header.trimmingCharacters(in: .whitespaces)),
           seconds >= 0 {
            let capped = min(seconds, RetryPolicy.seconds(of: policy.maxDelay))
            try await clock.sleep(for: .seconds(capped))
            return
        }

        let delay = policy.delay(afterAttempt: attempt, jitterFactor: jitter.nextFactor())
        try await clock.sleep(for: delay)
    }
}
