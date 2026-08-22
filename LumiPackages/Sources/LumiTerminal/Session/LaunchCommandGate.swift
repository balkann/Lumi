import Foundation

/// Spawn'daki başlangıç komutunu (ör. `claude --session-id <id>`) shell hazır
/// olana dek tutan kapı (spec/10 §2 — quiescence-gate kararı).
///
/// Komut PTY'ye spawn anında yazılınca shell startup'ında stdin okuyan interaktif
/// sorular (oh-my-zsh "update? [Y/n]" vb.) ilk karakterleri yutuyordu
/// (`claude` → `laude`). Kapı, çıktı-sessizliğinde (PromptScanTimer quiescence)
/// ekranın alt satırlarıyla sorgulanır: ekran hâlâ boşsa ya da son dolu satır
/// tek-tuş onay sorusuyla bitiyorsa bekler; aksi halde komutu bir kez teslim eder.
struct LaunchCommandGate {
    /// Satır sonunda cevap bekleyen tek-tuş onay kalıbı: `[Y/n]`, `(y/N)`,
    /// `[yes/no]:` vb. — ardında yalnız `:`/`?` ve boşluk olabilir.
    /// (Regex Sendable olmadığından Swift 6'da static tutulamaz — instance let.)
    private let questionTail = /[\[(]\s*y(es)?\s*\/\s*n(o)?\s*[\])]\s*[:?]?\s*$/
        .ignoresCase()

    private var pending: String?

    /// Teşhis için: komut hâlâ bekliyor mu? (DiagLog "hold" kaydı)
    var isPending: Bool { pending != nil }

    mutating func arm(_ command: String) {
        pending = command
    }

    /// Quiescence anında çağrılır. Enjeksiyon güvenliyse komutu döndürüp kapıyı
    /// boşaltır; shell henüz hazır değilse nil döner ve komut beklemede kalır.
    mutating func commandToInject(bottomLines: [String]) -> String? {
        guard let command = pending else { return nil }
        let lastContent = bottomLines.last {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard let line = lastContent else { return nil }
        guard line.firstMatch(of: questionTail) == nil else { return nil }
        pending = nil
        return command
    }
}
