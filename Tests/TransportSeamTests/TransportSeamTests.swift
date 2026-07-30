import XCTest
@testable import TransportSeam

// MARK: - Test doubles

/// Records what it was asked to wait for instead of actually waiting, so the
/// backoff ladder can be asserted exactly and the suite still runs in milliseconds.
actor RecordingClock: RetryClock {
    private var sleeps: [Duration] = []

    func sleep(for duration: Duration) async throws {
        sleeps.append(duration)
    }

    func recorded() -> [Duration] { sleeps }
}

private func milliseconds(_ duration: Duration) -> Double {
    RetryPolicy.seconds(of: duration) * 1000
}

private let testBaseURL = URL(string: "https://status.example.com/v1")
    ?? URL(fileURLWithPath: "/v1")

// MARK: - Currency types

final class HTTPFieldsTests: XCTestCase {
    func testLookupIsCaseInsensitive() {
        let fields: HTTPFields = [("Content-Type", "application/json")]
        XCTAssertEqual(fields["content-type"], "application/json")
        XCTAssertEqual(fields["CONTENT-TYPE"], "application/json")
        XCTAssertNil(fields["content-length"])
    }

    func testMultipleValuesArePreservedInOrder() {
        var fields = HTTPFields()
        fields.append("Set-Cookie", "a=1")
        fields.append("set-cookie", "b=2")

        XCTAssertEqual(fields.values(for: "Set-Cookie"), ["a=1", "b=2"])
        XCTAssertEqual(fields.first("Set-Cookie"), "a=1")
        XCTAssertEqual(fields.count, 2)
    }

    func testSetReplacesAllOccurrencesAndKeepsPosition() {
        var fields: HTTPFields = [("A", "1"), ("Dup", "x"), ("B", "2"), ("dup", "y")]
        fields.set("DUP", to: "z")

        XCTAssertEqual(fields.values(for: "dup"), ["z"])
        XCTAssertEqual(fields.map(\.value), ["1", "z", "2"])
    }

    func testSetAppendsWhenAbsent() {
        var fields = HTTPFields()
        fields.set("Accept", to: "application/json")
        XCTAssertEqual(fields["accept"], "application/json")
        XCTAssertEqual(fields.count, 1)
    }

    func testSetIfAbsentDoesNotOverrideCallerIntent() {
        var fields: HTTPFields = [("Accept", "text/csv")]
        fields.setIfAbsent("Accept", "application/json")
        XCTAssertEqual(fields.values(for: "accept"), ["text/csv"])
    }

    func testRemoveAndEmptyState() {
        var fields: HTTPFields = [("A", "1"), ("a", "2")]
        fields.remove("A")
        XCTAssertTrue(fields.isEmpty)
        XCTAssertNil(fields["a"])
        XCTAssertEqual(fields.values(for: "a"), [])
    }

    func testSubscriptSetterRemovesOnNil() {
        var fields: HTTPFields = [("A", "1")]
        fields["a"] = nil
        XCTAssertTrue(fields.isEmpty)
    }
}

final class HTTPStatusTests: XCTestCase {
    func testTransientClassification() {
        XCTAssertTrue(HTTPStatus(408).isTransient)
        XCTAssertTrue(HTTPStatus(429).isTransient)
        XCTAssertTrue(HTTPStatus(500).isTransient)
        XCTAssertTrue(HTTPStatus(503).isTransient)

        // Permanent statements about server capability: retrying wastes battery.
        XCTAssertFalse(HTTPStatus(501).isTransient)
        XCTAssertFalse(HTTPStatus(505).isTransient)

        XCTAssertFalse(HTTPStatus(200).isTransient)
        XCTAssertFalse(HTTPStatus(404).isTransient)
        XCTAssertFalse(HTTPStatus(422).isTransient)
    }

    func testMethodIdempotency() {
        // The full RFC 9110 §9.2.2 idempotent set.
        XCTAssertTrue(HTTPMethod.get.isIdempotent)
        XCTAssertTrue(HTTPMethod.head.isIdempotent)
        XCTAssertTrue(HTTPMethod.put.isIdempotent)
        XCTAssertTrue(HTTPMethod.delete.isIdempotent)
        XCTAssertTrue(HTTPMethod.options.isIdempotent)
        XCTAssertTrue(HTTPMethod.trace.isIdempotent)

        XCTAssertFalse(HTTPMethod.post.isIdempotent)
        XCTAssertFalse(HTTPMethod.patch.isIdempotent)

        // An unrecognised verb is treated as unsafe to repeat.
        XCTAssertFalse(HTTPMethod("PROPFIND").isIdempotent)

        XCTAssertEqual(HTTPMethod("get"), .get)
    }
}

// MARK: - Retry policy maths

final class RetryPolicyTests: XCTestCase {
    func testExponentialLadderWithoutJitter() {
        let policy = RetryPolicy(maxAttempts: 4, baseDelay: .milliseconds(200), multiplier: 2)

        XCTAssertEqual(milliseconds(policy.delay(afterAttempt: 1, jitterFactor: 1)), 200, accuracy: 0.001)
        XCTAssertEqual(milliseconds(policy.delay(afterAttempt: 2, jitterFactor: 1)), 400, accuracy: 0.001)
        XCTAssertEqual(milliseconds(policy.delay(afterAttempt: 3, jitterFactor: 1)), 800, accuracy: 0.001)
    }

    func testCeilingIsRespected() {
        let policy = RetryPolicy(maxAttempts: 10, baseDelay: .seconds(1), multiplier: 10, maxDelay: .seconds(5))
        XCTAssertEqual(milliseconds(policy.delay(afterAttempt: 4, jitterFactor: 1)), 5000, accuracy: 0.001)
    }

    func testJitterScalesAndClamps() {
        let policy = RetryPolicy(baseDelay: .milliseconds(400), multiplier: 2)
        XCTAssertEqual(milliseconds(policy.delay(afterAttempt: 1, jitterFactor: 0.5)), 200, accuracy: 0.001)
        XCTAssertEqual(milliseconds(policy.delay(afterAttempt: 1, jitterFactor: 0)), 0, accuracy: 0.001)
        XCTAssertEqual(milliseconds(policy.delay(afterAttempt: 1, jitterFactor: 9)), 400, accuracy: 0.001)
        XCTAssertEqual(milliseconds(policy.delay(afterAttempt: 1, jitterFactor: -3)), 0, accuracy: 0.001)
    }

    func testDegenerateInputsAreClamped() {
        XCTAssertEqual(RetryPolicy(maxAttempts: 0).maxAttempts, 1)
        XCTAssertEqual(RetryPolicy(maxAttempts: -7).maxAttempts, 1)
        XCTAssertEqual(RetryPolicy(multiplier: 0.1).multiplier, 1)

        let policy = RetryPolicy()
        XCTAssertEqual(milliseconds(policy.delay(afterAttempt: 0, jitterFactor: 1)), 0, accuracy: 0.001)
        XCTAssertEqual(milliseconds(policy.delay(afterAttempt: -5, jitterFactor: 1)), 0, accuracy: 0.001)
    }
}

// MARK: - Retry behaviour

final class RetryMiddlewareTests: XCTestCase {
    private func chain(
        transport: any HTTPTransport,
        policy: RetryPolicy,
        clock: RecordingClock
    ) -> MiddlewareTransport {
        transport.wrapped(in: [
            RetryMiddleware(policy: policy, clock: clock, jitter: FixedJitter(1))
        ])
    }

    func testTransientStatusesAreRetriedUntilSuccess() async throws {
        let transport = ScriptedTransport(responses: [
            HTTPResponse(status: 500),
            HTTPResponse(status: 503),
            StatusFixtures.okResponse
        ], repeatsLastStep: false)

        let clock = RecordingClock()
        let stack = chain(transport: transport, policy: RetryPolicy(maxAttempts: 3), clock: clock)

        let response = try await stack.send(HTTPRequest(url: testBaseURL))

        XCTAssertEqual(response.status, .ok)
        let sends = await transport.sendCount()
        XCTAssertEqual(sends, 3)

        let sleeps = await clock.recorded().map(milliseconds)
        XCTAssertEqual(sleeps.count, 2)
        XCTAssertEqual(sleeps[0], 200, accuracy: 0.001)
        XCTAssertEqual(sleeps[1], 400, accuracy: 0.001)
    }

    func testNonIdempotentRequestIsNeverRetried() async throws {
        let transport = ScriptedTransport(responses: [HTTPResponse(status: 500)])
        let clock = RecordingClock()
        let stack = chain(transport: transport, policy: RetryPolicy(maxAttempts: 5), clock: clock)

        let response = try await stack.send(HTTPRequest(method: .post, url: testBaseURL))

        XCTAssertEqual(response.status, HTTPStatus(500))
        let sends = await transport.sendCount()
        XCTAssertEqual(sends, 1, "a POST with no idempotency key must be sent exactly once")
        let sleeps = await clock.recorded()
        XCTAssertTrue(sleeps.isEmpty)
    }

    func testIdempotencyKeyMakesAPostRetryable() async throws {
        let transport = ScriptedTransport(responses: [
            HTTPResponse(status: 503),
            HTTPResponse(status: 200)
        ], repeatsLastStep: false)

        let clock = RecordingClock()
        let stack = chain(transport: transport, policy: RetryPolicy(maxAttempts: 3), clock: clock)

        let request = HTTPRequest(method: .post, url: testBaseURL, idempotencyKey: "ack-42")
        let response = try await stack.send(request)

        XCTAssertEqual(response.status, .ok)
        let sends = await transport.sendCount()
        XCTAssertEqual(sends, 2)
    }

    func testRetryAfterHeaderOverridesBackoff() async throws {
        let transport = ScriptedTransport(responses: [
            HTTPResponse(status: .tooManyRequests, fields: [("Retry-After", " 3 ")]),
            HTTPResponse(status: 200)
        ], repeatsLastStep: false)

        let clock = RecordingClock()
        let stack = chain(transport: transport, policy: RetryPolicy(maxAttempts: 3), clock: clock)

        _ = try await stack.send(HTTPRequest(url: testBaseURL))

        let sleeps = await clock.recorded().map(milliseconds)
        XCTAssertEqual(sleeps, [3000])
    }

    func testRetryAfterIsCappedByMaxDelay() async throws {
        let transport = ScriptedTransport(responses: [
            HTTPResponse(status: .tooManyRequests, fields: [("Retry-After", "600")]),
            HTTPResponse(status: 200)
        ], repeatsLastStep: false)

        let clock = RecordingClock()
        let policy = RetryPolicy(maxAttempts: 2, maxDelay: .seconds(8))
        let stack = chain(transport: transport, policy: policy, clock: clock)

        _ = try await stack.send(HTTPRequest(url: testBaseURL))

        let sleeps = await clock.recorded().map(milliseconds)
        XCTAssertEqual(sleeps, [8000])
    }

    func testExhaustionReturnsTheLastRealResponse() async throws {
        let transport = ScriptedTransport(responses: [HTTPResponse(status: 503)])
        let clock = RecordingClock()
        let stack = chain(transport: transport, policy: RetryPolicy(maxAttempts: 3), clock: clock)

        let response = try await stack.send(HTTPRequest(url: testBaseURL))

        XCTAssertEqual(response.status, HTTPStatus(503), "exhaustion must not invent a synthetic error")
        let sends = await transport.sendCount()
        XCTAssertEqual(sends, 3)
    }

    func testPermanentFailuresAreNotRetried() async throws {
        let transport = ScriptedTransport(responses: [HTTPResponse(status: 404)])
        let clock = RecordingClock()
        let stack = chain(transport: transport, policy: RetryPolicy(maxAttempts: 4), clock: clock)

        _ = try await stack.send(HTTPRequest(url: testBaseURL))

        let sends = await transport.sendCount()
        XCTAssertEqual(sends, 1)
    }

    func testTransportErrorsAreRetriedThenRethrown() async throws {
        let transport = ScriptedTransport(script: [.fail(.unreachable(reason: "airplane mode"))])
        let clock = RecordingClock()
        let stack = chain(transport: transport, policy: RetryPolicy(maxAttempts: 3), clock: clock)

        do {
            _ = try await stack.send(HTTPRequest(url: testBaseURL))
            XCTFail("expected the original transport error to surface")
        } catch let error as TransportError {
            XCTAssertEqual(error, .unreachable(reason: "airplane mode"))
        }

        let sends = await transport.sendCount()
        XCTAssertEqual(sends, 3)
    }

    func testMalformedResponsesAreNotRetried() async throws {
        let transport = ScriptedTransport(script: [.fail(.malformedResponse(reason: "not http"))])
        let clock = RecordingClock()
        let stack = chain(transport: transport, policy: RetryPolicy(maxAttempts: 4), clock: clock)

        do {
            _ = try await stack.send(HTTPRequest(url: testBaseURL))
            XCTFail("expected throw")
        } catch let error as TransportError {
            XCTAssertEqual(error, .malformedResponse(reason: "not http"))
        }

        let sends = await transport.sendCount()
        XCTAssertEqual(sends, 1)
    }
}

// MARK: - Middleware composition

final class MiddlewareCompositionTests: XCTestCase {
    func testDefaultFieldsDoNotOverrideCallerValues() async throws {
        let transport = ScriptedTransport(responses: [HTTPResponse(status: 200)])
        let stack = transport.wrapped(in: [
            DefaultFieldsMiddleware([("Accept", "application/json"), ("X-Client", "seam-demo")])
        ])

        _ = try await stack.send(
            HTTPRequest(url: testBaseURL, fields: [("Accept", "text/csv")])
        )

        let sent = await transport.recordedRequests()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].fields.values(for: "Accept"), ["text/csv"])
        XCTAssertEqual(sent[0].fields["x-client"], "seam-demo")
    }

    func testBearerTokenIsResolvedAtSendTime() async throws {
        let transport = ScriptedTransport(responses: [HTTPResponse(status: 200)])
        let stack = transport.wrapped(in: [BearerTokenMiddleware { "token-abc" }])

        _ = try await stack.send(HTTPRequest(url: testBaseURL))

        let sent = await transport.recordedRequests()
        XCTAssertEqual(sent[0].fields["authorization"], "Bearer token-abc")
    }

    func testLoggingSeesEveryPhysicalAttempt() async throws {
        let transport = ScriptedTransport(responses: [
            HTTPResponse(status: 500),
            HTTPResponse(status: 500),
            HTTPResponse(status: 200)
        ], repeatsLastStep: false)

        let log = TransportLog()
        let clock = RecordingClock()

        // Retry sits outside logging, so logging records one line per real send.
        let stack = transport.wrapped(in: [
            RetryMiddleware(policy: RetryPolicy(maxAttempts: 3), clock: clock, jitter: FixedJitter(1)),
            LoggingMiddleware(log: log)
        ])

        _ = try await stack.send(HTTPRequest(url: testBaseURL.appendingPathComponent("status")))

        let entries = await log.snapshot()
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.map(\.attempt), [1, 2, 3])
        XCTAssertEqual(entries.last?.outcome, .completed(.ok))
        XCTAssertEqual(entries.first?.path, "/v1/status")
    }
}

// MARK: - Feature layer

final class ServiceStatusClientTests: XCTestCase {
    func testDecodesStatusPayload() async throws {
        let transport = ScriptedTransport(responses: [StatusFixtures.okResponse])
        let client = ServiceStatusClient(baseURL: testBaseURL, transport: transport)

        let statuses = try await client.fetchStatuses()

        XCTAssertEqual(statuses.count, 4)
        XCTAssertEqual(statuses[0].id, "edge")
        XCTAssertEqual(statuses[1].state, .degraded)
        XCTAssertEqual(statuses[1].latencyMilliseconds, 734)
        XCTAssertEqual(statuses[3].state, .outage)
    }

    func testEmptyBodyIsAnEmptyListNotAFailure() async throws {
        let transport = ScriptedTransport(responses: [HTTPResponse(status: .noContent)])
        let client = ServiceStatusClient(baseURL: testBaseURL, transport: transport)

        let statuses = try await client.fetchStatuses()
        XCTAssertTrue(statuses.isEmpty)
    }

    func testNonSuccessSurfacesAsStatusError() async throws {
        let transport = ScriptedTransport(responses: [HTTPResponse(status: 403)])
        let client = ServiceStatusClient(baseURL: testBaseURL, transport: transport)

        do {
            _ = try await client.fetchStatuses()
            XCTFail("expected HTTPStatusError")
        } catch let error as HTTPStatusError {
            XCTAssertEqual(error.status, HTTPStatus(403))
        }
    }

    func testGarbageBodyBecomesMalformedResponse() async throws {
        let transport = ScriptedTransport(responses: [
            HTTPResponse(status: 200, body: Data("<html>nope</html>".utf8))
        ])
        let client = ServiceStatusClient(baseURL: testBaseURL, transport: transport)

        do {
            _ = try await client.fetchStatuses()
            XCTFail("expected malformedResponse")
        } catch let error as TransportError {
            guard case .malformedResponse = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testAcknowledgeCarriesItsIdempotencyKey() async throws {
        let transport = ScriptedTransport(responses: [HTTPResponse(status: 202)])
        let client = ServiceStatusClient(baseURL: testBaseURL, transport: transport)

        let status = try await client.acknowledge(incidentID: "media", idempotencyKey: "ack-7")

        XCTAssertEqual(status, HTTPStatus(202))
        let sent = await transport.recordedRequests()
        XCTAssertEqual(sent[0].method, .post)
        XCTAssertEqual(sent[0].fields["idempotency-key"], "ack-7")
        XCTAssertTrue(sent[0].isSafelyRepeatable)
        XCTAssertEqual(sent[0].url.path, "/v1/incidents/media/ack")
    }
}

// MARK: - The point of the whole exercise

/// The same feature-level expectations, run against two structurally different
/// transports. If this suite ever needs a per-transport branch, the seam has
/// leaked and a stack migration has stopped being free.
final class TransportSwapTests: XCTestCase {
    private func assertClientBehaviour(over transport: any HTTPTransport) async throws {
        let client = ServiceStatusClient(baseURL: testBaseURL, transport: transport)
        let statuses = try await client.fetchStatuses()

        XCTAssertEqual(statuses.map(\.id), ["edge", "sync", "push", "media"])
        XCTAssertEqual(statuses.filter { $0.state == .operational }.count, 2)
    }

    func testScriptedTransportSatisfiesTheContract() async throws {
        try await assertClientBehaviour(over: ScriptedTransport(responses: [StatusFixtures.okResponse]))
    }

    func testLoopbackTransportSatisfiesTheSameContract() async throws {
        let routes: [LoopbackTransport.Route: HTTPResponse] = [
            .init(method: .get, path: "/v1/status"): StatusFixtures.okResponse
        ]
        try await assertClientBehaviour(over: LoopbackTransport(routes: routes))
    }

    func testRetryStackSatisfiesTheSameContractOverAFlakyServer() async throws {
        let routes: [LoopbackTransport.Route: HTTPResponse] = [
            .init(method: .get, path: "/v1/status"): StatusFixtures.okResponse
        ]
        let flaky = FlakyTransport(base: LoopbackTransport(routes: routes), failures: 2)
        let stack = flaky.wrapped(in: [
            RetryMiddleware(policy: RetryPolicy(maxAttempts: 3), clock: RecordingClock(), jitter: FixedJitter(1))
        ])

        try await assertClientBehaviour(over: stack)
    }

    func testUnroutedPathIsA404NotACrash() async throws {
        let transport = LoopbackTransport(routes: [:])
        let client = ServiceStatusClient(baseURL: testBaseURL, transport: transport)

        do {
            _ = try await client.fetchStatuses()
            XCTFail("expected 404")
        } catch let error as HTTPStatusError {
            XCTAssertEqual(error.status, HTTPStatus(404))
        }
    }

    func testEmptyScriptFailsLoudlyRatherThanSilently() async throws {
        let transport = ScriptedTransport(script: [])

        do {
            _ = try await transport.send(HTTPRequest(url: testBaseURL))
            XCTFail("expected malformedResponse")
        } catch let error as TransportError {
            guard case .malformedResponse = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }
}
