import Foundation

/// Unverified JWT payload claims. Only used to read expiry/email from tokens we already trust.
struct JWT {
    let claims: [String: Any]

    init?(_ token: String) {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        claims = object
    }

    var expiresAt: Date? {
        (claims["exp"] as? Double).map { Date(timeIntervalSince1970: $0) }
    }

    func string(_ key: String) -> String? {
        claims[key] as? String
    }

    func nested(_ key: String, _ inner: String) -> String? {
        (claims[key] as? [String: Any])?[inner] as? String
    }
}
