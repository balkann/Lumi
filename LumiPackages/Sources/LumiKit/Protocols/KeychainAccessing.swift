import Foundation

/// Bir Keychain okumasının ÜÇ ayrı sonucu (karar 56 sertleştirmesi).
///
/// "Kayıt yok" ile "okuyamadım"ı ayırmak güvenlik gereğidir: kilitli bir
/// keychain, kullanıcının erişim diyaloğunu reddetmesi ve timeout, kayıt
/// gerçekten yokmuş gibi ele alınırsa çağıran taraf yüzeyi boşaltıp
/// kullanıcının oturumunu kapatabilir.
public enum KeychainReadResult: Sendable, Equatable {
    case found(String)
    case missing
    case failed(detail: String)

    /// Yalnız "bulundu" hâlinin değeri; `missing` ve `failed` için nil.
    /// Hata ile yokluğun aynı sayılabildiği yerlerde (örn. salt-gösterim)
    /// kullanılır — karar verme yollarında `switch` şarttır.
    public var value: String? {
        guard case let .found(value) = self else { return nil }
        return value
    }

    public var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// macOS Keychain sınırı (karar 56). Claude'un OAuth credentials'ı ve Lumi'nin
/// yönettiği kopyaları buradan geçer — testler gerçek keychain'e dokunmaz.
///
/// Yazma/silme hata fırlatır, çünkü başarısız bir yazım hesap değiştirmeyi
/// yarıda bırakır ve çağıranın geri alması gerekir.
public protocol KeychainAccessing: Sendable {
    func password(service: String, account: String) async -> KeychainReadResult
    func setPassword(_ value: String, service: String, account: String) async throws
    func deletePassword(service: String, account: String) async throws
}
