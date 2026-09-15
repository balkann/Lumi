import Foundation

/// Claude'un çalışma-alanı güven işaretini önceden `true` yapar
/// (`~/.claude.json` → `projects[<repoPath>].hasTrustDialogAccepted`).
///
/// Neden: remote'tan (telefon) başlatılan bir claude oturumu ilk açılışta
/// "Do you trust the files in this folder?" menüsünde bekler; bu menü chat
/// modundan görülemez/yanıtlanamaz ve claude transcript yazmadığı için chat
/// sonsuza dek "yükleniyor"da kalır. Güven artifact'ini önceden yazmak
/// dokümante edilen tek bypass'tır (`--dangerously-skip-permissions` ise TÜM
/// izin prompt'larını da kapatır — güven ile eşdeğer değildir).
public protocol ClaudeWorkspaceTrusting: Sendable {
    /// Verilen çalışma alanını güvenli işaretle. Idempotent ve best-effort:
    /// başarısızlık spawn'ı engellemez.
    func markTrusted(repoPath: String)
}
