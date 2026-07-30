import Foundation

public struct ServiceStatus: Codable, Hashable, Sendable, Identifiable {
    public enum State: String, Codable, Hashable, Sendable {
        case operational
        case degraded
        case outage
    }

    public let id: String
    public let name: String
    public let state: State
    public let latencyMilliseconds: Int

    public init(id: String, name: String, state: State, latencyMilliseconds: Int) {
        self.id = id
        self.name = name
        self.state = state
        self.latencyMilliseconds = latencyMilliseconds
    }
}

/// The feature layer.
///
/// Read the stored properties: a base `URL` and `any HTTPTransport`. There is no
/// `URLSession`, no `URLRequest`, no `Alamofire.Session`, no `GRPCChannel`. That
/// absence is the entire architectural claim — when the stack underneath changes,
/// this file does not.
public struct ServiceStatusClient: Sendable {
    private let baseURL: URL
    private let transport: any HTTPTransport
    private let decoder: JSONDecoder

    public init(baseURL: URL, transport: any HTTPTransport) {
        self.baseURL = baseURL
        self.transport = transport

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    public func fetchStatuses() async throws -> [ServiceStatus] {
        let request = HTTPRequest(
            method: .get,
            url: baseURL.appendingPathComponent("status"),
            fields: [("Accept", "application/json")]
        )

        let response = try await transport.send(request)

        guard response.status.isSuccess else {
            throw HTTPStatusError(response: response)
        }

        // 204 is a legitimate "nothing to report", not a decoding failure.
        guard !response.body.isEmpty else {
            return []
        }

        do {
            return try decoder.decode([ServiceStatus].self, from: response.body)
        } catch {
            throw TransportError.malformedResponse(reason: "status payload did not decode: \(error)")
        }
    }

    /// A write, and therefore the interesting case for retries.
    ///
    /// It carries an idempotency key precisely so the retry layer is allowed to
    /// re-send it. Drop the key and the same middleware chain will correctly
    /// refuse to retry this call.
    @discardableResult
    public func acknowledge(incidentID: String, idempotencyKey: String) async throws -> HTTPStatus {
        var fields: HTTPFields = [("Content-Type", "application/json")]
        fields.append("Idempotency-Key", idempotencyKey)

        let request = HTTPRequest(
            method: .post,
            url: baseURL.appendingPathComponent("incidents").appendingPathComponent(incidentID).appendingPathComponent("ack"),
            fields: fields,
            body: Data("{\"acknowledged\":true}".utf8),
            idempotencyKey: idempotencyKey
        )

        let response = try await transport.send(request)

        guard response.status.isSuccess else {
            throw HTTPStatusError(response: response)
        }

        return response.status
    }
}

// MARK: - Sample payloads

public enum StatusFixtures {
    public static let json = """
    [
      {"id":"edge","name":"Edge Gateway","state":"operational","latency_milliseconds":41},
      {"id":"sync","name":"Sync Engine","state":"degraded","latency_milliseconds":734},
      {"id":"push","name":"Push Delivery","state":"operational","latency_milliseconds":88},
      {"id":"media","name":"Media Pipeline","state":"outage","latency_milliseconds":0}
    ]
    """

    public static var data: Data { Data(json.utf8) }

    public static var okResponse: HTTPResponse {
        HTTPResponse(
            status: .ok,
            fields: [("Content-Type", "application/json")],
            body: data
        )
    }
}
