import Foundation

/// Pure pieces of the realtime protocol: the socket URL, outgoing messages and incoming frames.
/// They are tested against the shared conformance fixtures.
public enum RelayProtocol {
    public static let defaultPath = "/v1/realtime/ws"
    public static let defaultURL = "https://api.sendrelay.com.ng\(defaultPath)"

    /// The socket URL for a token: https becomes wss, a bare host gets https, and the default path
    /// is added when the URL has none.
    public static func webSocketURL(
        baseURL: String = defaultURL,
        token: String,
        deviceId: String? = nil,
        connectionType: String = "APP"
    ) throws -> URL {
        var text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw RelayError.invalidURL("empty") }
        if !text.contains("://") { text = "https://\(text)" }
        guard var parts = URLComponents(string: text), let host = parts.host, !host.isEmpty else {
            throw RelayError.invalidURL(baseURL)
        }
        switch parts.scheme?.lowercased() {
        case "https", "wss": parts.scheme = "wss"
        case "http", "ws": parts.scheme = "ws"
        default: throw RelayError.invalidURL("unsupported scheme in \(baseURL)")
        }
        if parts.port == 0 { parts.port = nil }
        if parts.path.isEmpty || parts.path == "/" { parts.path = defaultPath }
        parts.fragment = nil
        var query = [("token", token), ("type", connectionType)]
        if let deviceId = deviceId?.trimmingCharacters(in: .whitespaces), !deviceId.isEmpty {
            query.append(("deviceId", deviceId))
        }
        // Escape everything but unreserved characters, so tokens with + / = survive intact.
        parts.percentEncodedQuery = query
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: unreserved) ?? $0.1)" }
            .joined(separator: "&")
        guard let url = parts.url else { throw RelayError.invalidURL(baseURL) }
        return url
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    public static func subscribe(taskId: String) -> [String: String] {
        ["action": "subscribe", "type": "task", "id": taskId]
    }

    public static func unsubscribe(taskId: String) -> [String: String] {
        ["action": "unsubscribe", "type": "task", "id": taskId]
    }

    public static let ping: [String: String] = ["action": "ping"]

    /// The event in a raw server frame, or nil for frames that aren't events (acknowledgements,
    /// pongs, unknown types). A `TASK_UPDATE` envelope is unwrapped.
    public static func parse(_ data: Data) -> RelayEvent? {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if object["type"] as? String == "TASK_UPDATE", let inner = object["data"] as? [String: Any] {
            object = inner
        }
        guard let type = object["type"] as? String,
              let payload = try? JSONSerialization.data(withJSONObject: object)
        else { return nil }
        let decoder = JSONDecoder()
        if type == "RIDER_LOCATION_UPDATE" {
            return (try? decoder.decode(RiderLocationUpdate.self, from: payload)).map(RelayEvent.riderLocation)
        }
        guard TaskEventType(rawValue: type) != nil else { return nil }
        return (try? decoder.decode(TaskEvent.self, from: payload)).map(RelayEvent.task)
    }

    /// Seconds until a JWT's `exp`, or nil when the token has no readable expiry.
    public static func secondsUntilExpiry(of token: String, now: Date = Date()) -> TimeInterval? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let exp = claims["exp"] as? Double
        else { return nil }
        return exp - now.timeIntervalSince1970
    }
}
