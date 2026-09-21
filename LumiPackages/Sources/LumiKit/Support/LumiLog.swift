import Foundation
import os

/// Teşhis izi (karar 83): tüm modüller aynı unified-log subsystem'ini paylaşır.
///
/// Okuma:
///   /usr/bin/log show --last 1h --predicate 'subsystem == "com.lumi.app"' --style compact
///
/// `NSLog` bu macOS'ta yalnız stderr'e düşer; kalıcı iz için `os.Logger` şarttır.
/// Dinamik değerler `privacy: .public` ile yazılmalı, aksi hâlde `<private>` görünür.
public enum LumiLog {
    public static let subsystem = "com.lumi.app"

    public static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    /// Log satırlarında terminal kimliği: UUID'nin ilk 8 karakteri.
    public static func short(_ id: TerminalID) -> String {
        String(id.raw.uuidString.prefix(8))
    }

    public static func short(_ id: TerminalID?) -> String {
        id.map(short) ?? "nil"
    }

    /// `Duration` → milisaniye (log satırları için).
    public static func milliseconds(_ duration: Duration) -> Int64 {
        let parts = duration.components
        return parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000
    }
}
