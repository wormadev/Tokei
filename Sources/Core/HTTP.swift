import Foundation

enum HTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// Sends the request and maps 401/403/429/non-2xx to `ProviderError`.
    /// `unauthorizedHint` is what the user should do when credentials are rejected.
    static func data(_ request: URLRequest, unauthorizedHint: String) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.badResponse("no HTTP response") }
        switch http.statusCode {
        case 200 ..< 300:
            return data
        case 401, 403:
            throw ProviderError.unauthorized(unauthorizedHint)
        case 429:
            throw ProviderError.rateLimited(retryAfter: retryAfter(http.value(forHTTPHeaderField: "Retry-After")))
        default:
            throw ProviderError.http(http.statusCode)
        }
    }

    static func json<T: Decodable>(_ type: T.Type, _ request: URLRequest, unauthorizedHint: String) async throws -> T {
        let data = try await data(request, unauthorizedHint: unauthorizedHint)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ProviderError.badResponse(String(describing: error).prefix(160).description)
        }
    }

    /// Retry-After is either delta-seconds or an HTTP date.
    static func retryAfter(_ value: String?, now: Date = .now) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }
}

extension URLRequest {
    init(_ url: String, method: String = "GET", headers: [String: String] = [:]) {
        self.init(url: URL(string: url)!)
        httpMethod = method
        for (key, value) in headers { setValue(value, forHTTPHeaderField: key) }
    }
}

enum ISODate {
    static func parse(_ string: String?) -> Date? {
        guard let string else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: string) { return date }
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        return day.date(from: string)
    }
}

/// Decodes numbers that some APIs send as strings.
struct FlexibleDouble: Decodable, Sendable {
    let value: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = number
        } else if let string = try? container.decode(String.self), let number = Double(string) {
            value = number
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "expected number")
        }
    }
}
