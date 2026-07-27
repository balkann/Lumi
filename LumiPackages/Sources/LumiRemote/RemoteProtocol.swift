import Foundation

/// Zarf codec'i — docs/spec/50-remote-protocol.md ile birebir.
enum RemoteProtocol {
    static let version = 1

    static func envelope(type: String, payload: [String: Any]) -> Data? {
        let dict: [String: Any] = ["v": version, "type": type, "payload": payload]
        return try? JSONSerialization.data(withJSONObject: dict)
    }

    static func decode(_ data: Data) -> (type: String, payload: [String: Any])? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              dict["v"] as? Int == version,
              let type = dict["type"] as? String,
              let payload = dict["payload"] as? [String: Any] else { return nil }
        return (type, payload)
    }

    static func decode(text: String) -> (type: String, payload: [String: Any])? {
        guard let data = text.data(using: .utf8) else { return nil }
        return decode(data)
    }
}

/// `press_key` sözleşmesi (protokol dokümanı): yalnız bu beş tuş.
func keySequence(for key: String) -> String? {
    switch key {
    case "1", "2", "3": return key
    case "enter": return "\r"
    case "esc": return "\u{1B}"
    default: return nil
    }
}

/// 1,2,4,8,…60 sn üstel geri çekilme.
struct ReconnectBackoff {
    private var attempt = 0
    private let capSeconds: Double = 60

    mutating func nextDelay() -> Double {
        let delay = min(pow(2, Double(attempt)), capSeconds)
        attempt += 1
        return delay
    }

    mutating func reset() { attempt = 0 }
}
