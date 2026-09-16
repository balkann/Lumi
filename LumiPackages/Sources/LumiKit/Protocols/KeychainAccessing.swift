import Foundation

/// macOS Keychain sınırı (karar 56). Claude'un OAuth credentials'ı ve Lumi'nin
/// yönettiği kopyaları buradan geçer — testler gerçek keychain'e dokunmaz.
///
/// Okuma sessiz-fail'dir (kayıt yoksa `nil`); yazma/silme hata fırlatır, çünkü
/// başarısız bir yazım hesap değiştirmeyi yarıda bırakır ve çağıranın rollback
/// yapması gerekir.
public protocol KeychainAccessing: Sendable {
    func password(service: String, account: String) async -> String?
    func setPassword(_ value: String, service: String, account: String) async throws
    func deletePassword(service: String, account: String) async throws
}
