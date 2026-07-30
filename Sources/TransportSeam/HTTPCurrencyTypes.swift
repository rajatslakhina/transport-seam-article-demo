import Foundation

// MARK: - Method

/// An HTTP method, modelled as an extensible value rather than a closed enum so
/// that a caller can express `PATCH`, `PROPFIND` or a vendor verb without a
/// library release.
public struct HTTPMethod: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue.uppercased()
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public var description: String { rawValue }

    public static let get = HTTPMethod("GET")
    public static let head = HTTPMethod("HEAD")
    public static let post = HTTPMethod("POST")
    public static let put = HTTPMethod("PUT")
    public static let patch = HTTPMethod("PATCH")
    public static let delete = HTTPMethod("DELETE")
    public static let options = HTTPMethod("OPTIONS")
    public static let trace = HTTPMethod("TRACE")

    /// Whether re-sending this request has the same effect as sending it once.
    ///
    /// This is the full idempotent set from RFC 9110 §9.2.2. The retry policy
    /// leans on it, because retrying a non-idempotent request is how you get
    /// duplicate charges. Anything not listed here — including a custom verb
    /// the library has never seen — is treated as unsafe to repeat.
    public var isIdempotent: Bool {
        switch self {
        case .get, .head, .put, .delete, .options, .trace: return true
        default: return false
        }
    }
}

// MARK: - Fields

/// A single header field. Names are stored case-folded because HTTP field names
/// are case-insensitive, but the original spelling is preserved for transports
/// that echo it back.
public struct HTTPField: Hashable, Sendable {
    public let name: String
    public let canonicalName: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.canonicalName = name.lowercased()
        self.value = value
    }
}

/// An ordered, case-insensitive, multi-value header collection.
///
/// This exists because `[String: String]` quietly loses two things HTTP
/// actually has: duplicate field names (`Set-Cookie`) and field order.
public struct HTTPFields: Hashable, Sendable, Sequence {
    private var storage: [HTTPField]

    public init() {
        self.storage = []
    }

    public init(_ pairs: [(String, String)]) {
        self.storage = pairs.map { HTTPField(name: $0.0, value: $0.1) }
    }

    /// First value for `name`, case-insensitively.
    public subscript(name: String) -> String? {
        get { first(name) }
        set {
            if let newValue {
                set(name, to: newValue)
            } else {
                remove(name)
            }
        }
    }

    public func first(_ name: String) -> String? {
        let key = name.lowercased()
        return storage.first { $0.canonicalName == key }?.value
    }

    /// Every value for `name`, in the order the transport delivered them.
    public func values(for name: String) -> [String] {
        let key = name.lowercased()
        return storage.filter { $0.canonicalName == key }.map(\.value)
    }

    /// Appends without disturbing an existing field of the same name.
    public mutating func append(_ name: String, _ value: String) {
        storage.append(HTTPField(name: name, value: value))
    }

    /// Replaces every existing field of that name with a single value, keeping
    /// the position of the first occurrence so header order stays stable.
    public mutating func set(_ name: String, to value: String) {
        let key = name.lowercased()
        let replacement = HTTPField(name: name, value: value)
        var result: [HTTPField] = []
        result.reserveCapacity(storage.count)
        var didReplace = false

        for field in storage {
            guard field.canonicalName == key else {
                result.append(field)
                continue
            }
            if !didReplace {
                result.append(replacement)
                didReplace = true
            }
        }

        if !didReplace {
            result.append(replacement)
        }
        storage = result
    }

    public mutating func remove(_ name: String) {
        let key = name.lowercased()
        storage.removeAll { $0.canonicalName == key }
    }

    /// Adds `name` only if the caller has not already supplied it. Used by
    /// middleware that wants to provide a default without overriding intent.
    public mutating func setIfAbsent(_ name: String, _ value: String) {
        guard first(name) == nil else { return }
        append(name, value)
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }

    public func makeIterator() -> Array<HTTPField>.Iterator {
        storage.makeIterator()
    }
}

extension HTTPFields: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: (String, String)...) {
        self.init(elements)
    }
}

// MARK: - Status

public struct HTTPStatus: Hashable, Sendable, ExpressibleByIntegerLiteral, CustomStringConvertible {
    public let code: Int

    public init(_ code: Int) { self.code = code }
    public init(integerLiteral value: Int) { self.init(value) }

    public var description: String { String(code) }

    public var isSuccess: Bool { (200..<300).contains(code) }
    public var isClientError: Bool { (400..<500).contains(code) }
    public var isServerError: Bool { (500..<600).contains(code) }

    /// The server-side conditions that are worth a second attempt. 501 and 505
    /// are excluded on purpose: they are permanent statements about the server's
    /// capabilities, and retrying them just spends battery.
    public var isTransient: Bool {
        if code == 408 || code == 425 || code == 429 { return true }
        guard isServerError else { return false }
        return code != 501 && code != 505
    }

    public static let ok = HTTPStatus(200)
    public static let noContent = HTTPStatus(204)
    public static let tooManyRequests = HTTPStatus(429)
    public static let internalServerError = HTTPStatus(500)
}

// MARK: - Request / Response

public struct HTTPRequest: Hashable, Sendable {
    public var method: HTTPMethod
    public var url: URL
    public var fields: HTTPFields
    public var body: Data?

    /// Set this on a `POST` you are willing to have retried. Without it the
    /// retry policy refuses to re-send a non-idempotent request.
    public var idempotencyKey: String?

    public init(
        method: HTTPMethod = .get,
        url: URL,
        fields: HTTPFields = HTTPFields(),
        body: Data? = nil,
        idempotencyKey: String? = nil
    ) {
        self.method = method
        self.url = url
        self.fields = fields
        self.body = body
        self.idempotencyKey = idempotencyKey
    }

    /// True when this request may be sent more than once without changing the
    /// outcome — either because the method says so, or because the caller
    /// supplied a de-duplication key the server honours.
    public var isSafelyRepeatable: Bool {
        method.isIdempotent || idempotencyKey != nil
    }
}

public struct HTTPResponse: Hashable, Sendable {
    public var status: HTTPStatus
    public var fields: HTTPFields
    public var body: Data

    public init(status: HTTPStatus, fields: HTTPFields = HTTPFields(), body: Data = Data()) {
        self.status = status
        self.fields = fields
        self.body = body
    }
}
