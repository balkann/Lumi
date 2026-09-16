import Foundation

/// Tıklanan linkin ne olduğu (karar 57). Çözümleme SAFTIR: dosya sisteminin
/// cevabı `pathKind` closure'ıyla dışarıdan verilir, repo/workspace kökleri
/// parametredir — store bu kararı test edilebilir bir tablodan okur.
public enum TerminalLinkTarget: Sendable, Equatable {
    /// http/https — sistemdeki varsayılan tarayıcıda açılır.
    case url(URL)
    /// Bilinen bir proje/workspace kökü → sekmeye geçilebilir.
    case workspace(path: String)
    case directory(path: String)
    /// Dosya. Diskte olmadığı durumda da bu vakadır: hata, eylem çalıştığında
    /// görünür biçimde raporlanır (karar 5 — sessiz yutma yok).
    case file(path: String)

    /// Popover başlığında gösterilen metin.
    public var displayText: String {
        switch self {
        case .url(let url): return url.absoluteString
        case .workspace(let path), .directory(let path), .file(let path): return path
        }
    }
}

/// Bir yolun diskteki karşılığı.
public enum TerminalLinkPathKind: Sendable, Equatable {
    case missing
    case file
    case directory
}

/// Ham link metnini hedefe çeviren saf çözümleyici.
public enum TerminalLinkResolver {
    /// Link metninin sonundaki `:satır[:sütun]` eki (derleyici/test çıktıları).
    /// Lumi FileViewer satıra atlamadığından yalnız ayıklanır.
    private static let lineSuffix = try? NSRegularExpression(pattern: #"(:\d+){1,2}$"#)
    /// Metnin başına/sonuna yapışan noktalama (cümle içindeki path'ler).
    private static let trimmedEdges = CharacterSet(charactersIn: "\"'`<>()[]{},;")

    public static func resolve(
        link: String,
        basePath: String,
        homeDirectory: String,
        knownRoots: [String],
        pathKind: (String) -> TerminalLinkPathKind
    ) -> TerminalLinkTarget? {
        let cleaned = link
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: trimmedEdges)
        guard !cleaned.isEmpty else { return nil }

        if let scheme = scheme(of: cleaned) {
            guard scheme == "http" || scheme == "https" else { return nil }
            guard let url = URL(string: cleaned) else { return nil }
            return .url(url)
        }

        guard let path = absolutePath(
            for: stripLineSuffix(cleaned), basePath: basePath, homeDirectory: homeDirectory
        ) else { return nil }

        let roots = Set(knownRoots.map(standardized))
        if roots.contains(path) { return .workspace(path: path) }
        return pathKind(path) == .directory ? .directory(path: path) : .file(path: path)
    }

    /// Yolu içeren EN YAKIN (en uzun) bilinen kök — FileViewer repo-göreli çalışır.
    public static func enclosingRoot(of path: String, in knownRoots: [String]) -> String? {
        knownRoots
            .map(standardized)
            .filter { path == $0 || path.hasPrefix($0 + "/") }
            .max(by: { $0.count < $1.count })
    }

    /// Köke göre göreli yol (FileViewer'ın beklediği biçim).
    public static func relativePath(of path: String, in root: String) -> String? {
        let root = standardized(root)
        guard path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }

    // MARK: - Yardımcılar

    private static func scheme(of text: String) -> String? {
        guard let separator = text.range(of: "://") else {
            // `mailto:`/`tel:` gibi şemalar da link yoluna girmemeli.
            guard let colon = text.firstIndex(of: ":") else { return nil }
            let candidate = String(text[text.startIndex ..< colon])
            let isScheme = !candidate.isEmpty && candidate.allSatisfy { $0.isLetter }
            return isScheme && candidate.count > 1 ? candidate.lowercased() : nil
        }
        return String(text[text.startIndex ..< separator.lowerBound]).lowercased()
    }

    private static func stripLineSuffix(_ text: String) -> String {
        guard let lineSuffix else { return text }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        guard let match = lineSuffix.firstMatch(in: text, range: range),
              let matched = Range(match.range, in: text),
              matched.lowerBound != text.startIndex else { return text }
        return String(text[text.startIndex ..< matched.lowerBound])
    }

    private static func absolutePath(
        for text: String, basePath: String, homeDirectory: String
    ) -> String? {
        if text.hasPrefix("/") { return standardized(text) }
        if text == "~" { return standardized(homeDirectory) }
        if text.hasPrefix("~/") {
            return standardized(homeDirectory + "/" + String(text.dropFirst(2)))
        }
        guard !basePath.isEmpty else { return nil }
        return standardized(basePath + "/" + text)
    }

    /// `.`/`..` sadeleştirmesi + sondaki `/` temizliği. Sembolik link ÇÖZÜLMEZ:
    /// kullanıcıya gösterilen yol, terminalde yazan yolla aynı kalmalı.
    private static func standardized(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        guard standardized.count > 1, standardized.hasSuffix("/") else { return standardized }
        return String(standardized.dropLast())
    }
}
