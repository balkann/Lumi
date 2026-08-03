import Foundation
import LumiKit

/// Aynı repo (proje dizini) altında eş zamanlı çalışan birden çok terminalin
/// transcript jsonl'lerini ayırt etmek için tekil sahiplik koordinatörü.
///
/// Sorun: `~/.claude/projects/<proje>/` dizini yalnız cwd'den türer; aynı repoda
/// açık N tab aynı dizini paylaşır. mtime sezgiseli tek başına hangi jsonl'in
/// hangi terminale ait olduğunu ayırt edemez → mesajlar tab'lar arası sızar.
///
/// Çözüm (tasarım riski §12.1'in nokta çözümü): jsonl'in **birthtime**'ı
/// (dosya yaratılma anı) ≈ Claude oturumunun başlangıcı ≈ terminalin
/// `createdAt`'i. Her terminali, `createdAt`'inden hemen sonra doğmuş,
/// başka terminalce sahiplenilmemiş jsonl'e **tekil** atarız. Atama, kayıtlı
/// terminaller + dizindeki dosyalardan her sorguda deterministik hesaplanır
/// (mutable claim state yok → yarış yok).
///
/// Tek terminal (kardeş yok) durumunda `.solo` döner; watcher mevcut mtime
/// sezgiselini (restart fallback dahil) kullanmaya devam eder.
actor TranscriptClaimRegistry {
    /// Terminalin `createdAt`'i ile jsonl birthtime'ı arasındaki, saatler aynı
    /// makinede olduğundan yalnız ölçüm/yuvarlama kaymasını karşılayan küçük
    /// pozitif tolerans. Terminal her zaman dosyadan ÖNCE yaratıldığından
    /// `createdAt <= birthtime` doğal olarak tutar; tolerans ters yöndeki
    /// milisaniye kaymaları içindir.
    private static let skewTolerance: TimeInterval = 2

    enum Assignment: Equatable {
        /// Bu dizinde tek terminal — watcher kendi mtime sezgiselini kullansın.
        case solo
        /// Bu terminale atanan jsonl.
        case file(URL)
        /// Kardeşler var ama bu terminale henüz eşleşen (yeterince taze) dosya yok
        /// — "yalnız durum modu"; eşleşene dek boş kalır (yanlış eşleşmektense boş).
        case unassigned
    }

    private struct Owner { let dir: URL; let createdAt: Date }
    private var owners: [TerminalID: Owner] = [:]

    func register(owner: TerminalID, dir: URL, createdAt: Date) {
        owners[owner] = Owner(dir: dir, createdAt: createdAt)
    }

    func unregister(owner: TerminalID) {
        owners[owner] = nil
    }

    func assignment(for owner: TerminalID) -> Assignment {
        guard let me = owners[owner] else { return .solo }
        // Aynı proje dizinini paylaşan terminaller. Tek başınaysa ayrıştırmaya
        // gerek yok — watcher mtime sezgiselini (restart fallback dahil) kullansın.
        let group = owners.filter { $0.value.dir == me.dir }
        guard group.count > 1 else { return .solo }

        // Her jsonl'i, doğduğu (birthtime) anda var olan EN SON yaratılmış (henüz
        // atanmamış) terminale ata: argmax { createdAt : createdAt <= birthtime + skew }.
        // Böylece (a) her terminal kendi oturumunun dosyasını alır, (b) eski oturum
        // dosyaları (birthtime << güncel createdAt'ler) hiçbir terminale atanmaz.
        // Atama deterministiktir (kayıtlı terminaller + dizin içeriği) — claim state yok.
        let files = candidateFiles(in: me.dir)   // birthtime artan
        var assigned: [TerminalID: URL] = [:]
        var takenOwners = Set<TerminalID>()
        for (url, birth) in files {
            let cutoff = birth.addingTimeInterval(Self.skewTolerance)
            let pick = group
                .filter { !takenOwners.contains($0.key) && $0.value.createdAt <= cutoff }
                .max { lhs, rhs in
                    lhs.value.createdAt == rhs.value.createdAt
                        ? lhs.key.raw.uuidString < rhs.key.raw.uuidString
                        : lhs.value.createdAt < rhs.value.createdAt
                }
            if let pick {
                assigned[pick.key] = url
                takenOwners.insert(pick.key)
            }
        }
        return assigned[owner].map { .file($0) } ?? .unassigned
    }

    /// Dizindeki jsonl'ler + birthtime'ları (yaratılma anı), birthtime artan sırada.
    private func candidateFiles(in dir: URL) -> [(URL, Date)] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey]
        ) else { return [] }
        return entries
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> (URL, Date)? in
                guard let birth = try? url.resourceValues(forKeys: [.creationDateKey])
                    .creationDate else { return nil }
                return (url, birth)
            }
            .sorted { $0.1 < $1.1 }
    }
}
