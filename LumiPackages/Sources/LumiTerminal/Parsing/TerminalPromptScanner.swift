import Foundation
import LumiKit

/// Görünür terminal alt-satırlarını interaktif prompt'a çeviren saf parser (spec 4 §1).
/// Emülatörden bağımsız: girdi `translateToString(trimRight:)` ile alınmış düz satırlardır.
enum TerminalPromptScanner {
    private static let footerNeedles = [
        "to select", "to navigate", "to proceed", "esc to cancel", "tab to amend", "↑/↓",
    ]
    private static let markerChars: Set<Character> = ["❯", "›", "▸", "*", ">"]
    private static let boxChars: Set<Character> = Set(
        "─│┌┐└┘├┤┬┴┼╭╮╯╰═║╔╗╚╝▏▕□▢☐")

    static func scan(lines: [String]) -> DetectedPrompt? {
        // (1) Footer imzası zorunlu — normal çıktı/yarı-render elenir.
        guard lines.contains(where: isFooter) else { return nil }

        // (2) İlk numaralı seçenek satırını bul.
        guard let firstOptIdx = lines.firstIndex(where: { parseOption($0) != nil }) else {
            return nil
        }

        // (3) Seçenek bloğu: numaralı satırlar + sarılan devam satırları.
        var options: [String] = []
        var idx = firstOptIdx
        while idx < lines.count {
            let raw = lines[idx]
            if isFooter(raw) { break }
            if let opt = parseOption(raw) {
                options.append(opt)
            } else {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { break }               // blok bitti
                if !options.isEmpty { options[options.count - 1] += " " + trimmed } // sarılan seçenek
            }
            idx += 1
        }
        guard !options.isEmpty else { return nil }

        // (4) Soru metni: seçeneklerin üstündeki en yakın boş-olmayan blok.
        var i = firstOptIdx - 1
        while i >= 0, cleanLine(lines[i]).isEmpty { i -= 1 }  // aradaki boşlukları atla
        var qLines: [String] = []
        while i >= 0 {
            let c = cleanLine(lines[i])
            // Yalnız boş satırda/başta dur (spec §1). Footer'lar seçeneklerin ALTINDadır;
            // yukarı tararken footer'a rastlanmaz — ve "Do you want to proceed?" gibi bir
            // SORU metni footer needle'ı ("to proceed") ile çakışırsa yanlış kırma olurdu.
            if c.isEmpty { break }
            qLines.insert(c, at: 0)
            i -= 1
        }
        let questionText = qLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)

        // (5) Kind (best-effort): options/soru "don't ask again"/"proceed" → izin;
        //     footer "to select"/"to navigate" → soru; aksi generic.
        let hay = (questionText + " " + options.joined(separator: " ")).lowercased()
        let footerText = lines.filter(isFooter).joined(separator: " ").lowercased()
        let kind: DetectedPrompt.Kind
        if hay.contains("don't ask again") || hay.contains("do you want to proceed") {
            kind = .permission
        } else if footerText.contains("to select") || footerText.contains("to navigate") {
            kind = .question
        } else {
            kind = .generic
        }

        return DetectedPrompt(kind: kind,
                              questionText: questionText.isEmpty ? nil : questionText,
                              options: options)
    }

    private static func isFooter(_ line: String) -> Bool {
        let l = line.lowercased()
        return footerNeedles.contains { l.contains($0) }
    }

    /// "❯ 1. Yes" / "  2. …" → seçenek metni; değilse nil.
    private static func parseOption(_ line: String) -> String? {
        var s = Substring(line).drop(while: { $0 == " " || $0 == "\t" })
        if let f = s.first, markerChars.contains(f) {
            s = s.dropFirst().drop(while: { $0 == " " })
        }
        let digits = s.prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return nil }
        s = s.dropFirst(digits.count)
        guard s.first == "." else { return nil }
        s = s.dropFirst()
        guard s.first == " " || s.isEmpty else { return nil }  // "1.5" gibi ondalıkları ele
        let text = s.drop(while: { $0 == " " }).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// Kutu-çizgi/checkbox karakterlerini söküp trim'ler (soru metni için).
    private static func cleanLine(_ line: String) -> String {
        String(line.filter { !boxChars.contains($0) }).trimmingCharacters(in: .whitespaces)
    }
}
