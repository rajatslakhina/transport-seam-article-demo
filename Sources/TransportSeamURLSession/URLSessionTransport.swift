import Foundation
import TransportSeam

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The only file in the package that knows `URLSession` exists.
///
/// Count the lines. Adapting a whole networking stack to the seam is a page of
/// mapping code — which is the argument for putting the seam in before you need
/// it, not after. When the Swift Networking Workgroup's HTTP client lands, the
/// migration is a sibling of this file plus one line in the composition root.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body

        for field in request.fields {
            // `addValue` rather than `setValue`, so repeated fields survive.
            urlRequest.addValue(field.value, forHTTPHeaderField: field.name)
        }

        let data: Data
        let urlResponse: URLResponse

        do {
            (data, urlResponse) = try await session.data(for: urlRequest)
        } catch is CancellationError {
            throw TransportError.cancelled
        } catch let error as URLError {
            throw URLSessionTransport.translate(error)
        } catch {
            throw TransportError.interrupted(reason: String(describing: error))
        }

        guard let http = urlResponse as? HTTPURLResponse else {
            throw TransportError.malformedResponse(reason: "response was not HTTP")
        }

        var fields = HTTPFields()
        for (key, value) in http.allHeaderFields {
            guard let name = key as? String, let value = value as? String else { continue }
            fields.append(name, value)
        }

        return HTTPResponse(status: HTTPStatus(http.statusCode), fields: fields, body: data)
    }

    /// `URLError` is a `URLSession` implementation detail. Translating it here is
    /// what keeps `URLError.notConnectedToInternet` out of a view model.
    static func translate(_ error: URLError) -> TransportError {
        switch error.code {
        case .cancelled:
            return .cancelled
        case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return .unreachable(reason: error.localizedDescription)
        case .timedOut, .networkConnectionLost:
            return .interrupted(reason: error.localizedDescription)
        case .badServerResponse, .cannotParseResponse:
            return .malformedResponse(reason: error.localizedDescription)
        default:
            return .interrupted(reason: error.localizedDescription)
        }
    }
}
