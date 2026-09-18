import Foundation
import LumiKit

/// `/usr/bin/security` tabanlı `KeychainAccessing` (karar 56).
///
/// Neden Security framework'ü değil: Lumi zaten Claude'un kaydını (karar 32)
/// `security` ile okuyor ve kullanıcı erişim iznini o binary'ye vermiş
/// durumda; iki farklı yoldan okumak ikinci bir izin diyaloğu çıkarırdı.
///
/// Yazarken parola `-X` ile HEX olarak geçilir. Bu ŞİFRELEME DEĞİLDİR: hex,
/// token'ın `ps` çıktısında düz metin olarak okunmasını engeller, aynı
/// kullanıcı altında koşan ve argümanları okuyup çözebilen bir sürece karşı
/// koruma sağlamaz. `security`'nin stdin'den parola alan bir kipi olmadığı
/// için argüman yolu şimdilik kaçınılmaz; alternatifi Security framework'üne
/// geçmektir (ayrı bir erişim izni diyaloğu doğurur).
public struct SecurityKeychain: KeychainAccessing {
    /// Keychain kilitliyse `security` kullanıcı etkileşimi bekler — UI'ı
    /// süresiz bekletmemek için kısa bir üst sınır.
    public static let timeout: TimeInterval = 10

    private let runner: any ProcessRunning

    public init(runner: any ProcessRunning = SystemProcessRunner()) {
        self.runner = runner
    }

    /// Çıkış kodu 0 → bulundu, 44 (`errSecItemNotFound`) → yok, geri kalan
    /// her şey (kilitli keychain, reddedilen erişim, timeout) → HATA.
    public func password(service: String, account: String) async -> KeychainReadResult {
        let result = await runner.run(
            Self.binary,
            arguments: ["find-generic-password", "-s", service, "-a", account, "-w"],
            timeout: Self.timeout
        )
        guard let result else { return .failed(detail: "security timed out") }
        guard result.exitCode == 0 else {
            return result.exitCode == Self.notFoundExitCode
                ? .missing
                : .failed(detail: Self.detail(result) ?? "exit \(result.exitCode)")
        }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // Exit 0 ama boş çıktı: kayıt var, parolası boş. Bunu "yok" saymak
        // yanlış olurdu; kimlik bilgisi olarak da geçersizdir.
        return value.isEmpty ? .missing : .found(value)
    }

    public func setPassword(_ value: String, service: String, account: String) async throws {
        let hex = Data(value.utf8).map { String(format: "%02x", $0) }.joined()
        let result = await runner.run(
            Self.binary,
            arguments: ["add-generic-password", "-U", "-s", service, "-a", account, "-X", hex],
            timeout: Self.timeout
        )
        guard let result, result.exitCode == 0 else {
            throw LumiError.claudeAccountFailed(
                operation: "keychain write",
                detail: Self.detail(result) ?? "security timed out"
            )
        }
    }

    /// Kayıt yoksa (exit 44) başarı sayılır: silmenin sonucu "yok" durumudur.
    public func deletePassword(service: String, account: String) async throws {
        let result = await runner.run(
            Self.binary,
            arguments: ["delete-generic-password", "-s", service, "-a", account],
            timeout: Self.timeout
        )
        guard let result else {
            throw LumiError.claudeAccountFailed(
                operation: "keychain delete", detail: "security timed out"
            )
        }
        guard result.exitCode != 0, result.exitCode != Self.notFoundExitCode else { return }
        throw LumiError.claudeAccountFailed(
            operation: "keychain delete", detail: Self.detail(result) ?? "unknown error"
        )
    }

    private static let binary = "/usr/bin/security"
    /// `errSecItemNotFound` — `security`'nin "could not be found" çıkışı.
    private static let notFoundExitCode: Int32 = 44

    private static func detail(_ result: ProcessOutput?) -> String? {
        guard let result else { return nil }
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return stderr.isEmpty ? "exit \(result.exitCode)" : stderr
    }
}
