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
        // (1) Claude footer imzası (to select/navigate/proceed…) birincil sinyaldir.
        //     Yoksa footer'sız konservatif kural (aşağıda §3.5) devreye girer.
        let hasFooter = lines.contains(where: isFooter)

        // (2) İlk numaralı seçenek satırını bul.
        guard let firstOptIdx = lines.firstIndex(where: { parseOption($0) != nil }) else {
            return nil
        }

        // (3) Seçenek bloğu: numaralı satırlar + sarılan devam satırları.
        var options: [String] = []
        var numbers: [Int] = []
        var lastOptIdx = firstOptIdx
        var hadWrap = false            // sarılan devam satırı görüldü mü (footer'sız yolda diskalifiye)
        var idx = firstOptIdx
        while idx < lines.count {
            let raw = lines[idx]
            if isFooter(raw) { break }
            if let opt = parseOption(raw) {
                options.append(opt.text)
                numbers.append(opt.number)
                lastOptIdx = idx
            } else {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { break }               // gerçek boş satır → blok bitti
                if cleanLine(raw).isEmpty { idx += 1; continue } // yalnız kutu-çizgi (ayraç) → şıklar arası, atla
                hadWrap = true
                if !options.isEmpty { options[options.count - 1] += " " + trimmed } // sarılan seçenek
            }
            idx += 1
        }
        guard !options.isEmpty else { return nil }

        // (3.5) Footer yoksa: üçüncü-parti CLI menülerini yakala ama false-positive'i ele.
        //   Kabul koşulu (hepsi): ≥2 şık, 1'den ardışık numaralar, sarılan-satır yok (temiz blok),
        //   ve blok ekranın en altına yaslı (altında yalnız boş satır). Aksi → prompt sayma.
        if !hasFooter {
            let sequential = numbers == Array(1...numbers.count)
            let bottomAnchored = lines[(lastOptIdx + 1)...].allSatisfy {
                $0.trimmingCharacters(in: .whitespaces).isEmpty
            }
            guard options.count >= 2, sequential, !hadWrap, bottomAnchored else { return nil }
        }

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

    /// Parse edilemeyen bekleyen prompt için telefonda gösterilecek ham ekran özeti:
    /// kutu-çizgileri ayıklanmış, boş satırlar atılmış son en fazla `max` dolu satır.
    static func screenTail(lines: [String], max n: Int = 6) -> [String] {
        let cleaned = lines.map(cleanLine).filter { !$0.isEmpty }
        return Array(cleaned.suffix(n))
    }

    private static func isFooter(_ line: String) -> Bool {
        let l = line.lowercased()
        return footerNeedles.contains { l.contains($0) }
    }

    /// "❯ 1. Yes" / "  2. …" → (numara, seçenek metni); değilse nil.
    private static func parseOption(_ line: String) -> (number: Int, text: String)? {
        var s = Substring(line).drop(while: { $0 == " " || $0 == "\t" })
        if let f = s.first, markerChars.contains(f) {
            s = s.dropFirst().drop(while: { $0 == " " })
        }
        let digits = s.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        s = s.dropFirst(digits.count)
        guard s.first == "." else { return nil }
        s = s.dropFirst()
        guard s.first == " " || s.isEmpty else { return nil }  // "1.5" gibi ondalıkları ele
        let text = s.drop(while: { $0 == " " }).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (number, text)
    }

    /// Kutu-çizgi/checkbox karakterlerini söküp trim'ler (soru metni için).
    private static func cleanLine(_ line: String) -> String {
        String(line.filter { !boxChars.contains($0) }).trimmingCharacters(in: .whitespaces)
    }
}
