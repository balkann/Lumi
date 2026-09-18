import Foundation
import LumiKit
import Observation

/// DeepSeek bakiye göstergesinin store'u (karar 75).
///
/// `UsageStore` ile aynı sözleşmeyi taşır — kapalı gösterge hiç istek atmaz,
/// hata son bakiyeyi KORUR (karar 5), manuel yenilemede anti-spam aralığı
/// uygulanır — ama ayrı bir tiptir: taşıdığı veri pencere/yüzde değil paradır.
/// Durum satırı `UsageStatusKind` ile ortaktır, böylece popover alt bilgisi
/// aynı bileşenden çizilir.
@Observable
@MainActor
public final class DeepSeekBalanceStore {
    public private(set) var balance: DeepSeekBalance?
    public private(set) var isLoading = false
    /// Son başarısızlığın kullanıcıya dönük mesajı (bakiye korunurken gösterilir).
    public private(set) var errorMessage: String?
    /// Config'teki gösterge anahtarı — kapalıyken hiçbir istek atılmaz.
    public private(set) var isEnabled = false

    /// Manuel yenileme için minimum aralık (anti-spam) — `UsageStore` ile aynı.
    public static let minRefreshInterval: TimeInterval = 60

    @ObservationIgnored private let service: any DeepSeekBalanceServicing
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var lastAttemptAt: Date?
    @ObservationIgnored private var hasLoadedOnce = false

    public init(
        service: any DeepSeekBalanceServicing,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.service = service
        self.now = now
    }

    // MARK: - Türevler

    /// Durum satırının tek kaynağı (`UsageStore.statusKind` ile aynı sıra).
    public var statusKind: UsageStatusKind {
        if isLoading { return .loading }
        if let fetchedAt = balance?.fetchedAt {
            guard let errorMessage else { return .updated(fetchedAt: fetchedAt) }
            return .staleWithError(fetchedAt: fetchedAt, message: errorMessage)
        }
        if let errorMessage { return .failed(message: errorMessage) }
        return .idle
    }

    public var canRefresh: Bool {
        if !isEnabled || isLoading { return false }
        guard let last = lastAttemptAt else { return true }
        return now().timeIntervalSince(last) >= Self.minRefreshInterval
    }

    // MARK: - Eylemler

    /// Config'ten gelen açık/kapalı durumu; kapatılınca "ilk yükleme yapıldı"
    /// bayrağı sıfırlanır (tekrar açıldığında gösterge boş kalmasın).
    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if !enabled { hasLoadedOnce = false }
    }

    public func loadInitialIfNeeded() async {
        guard isEnabled, !hasLoadedOnce else { return }
        await performFetch()
    }

    public func refresh() async {
        guard canRefresh else { return }
        await performFetch()
    }

    /// Anahtar değişti (Settings ▸ Agent'ta kaydedildi/silindi): ekrandaki
    /// bakiye artık başka bir hesaba ait olabileceği için anti-spam aralığı
    /// UYGULANMAZ — `UsageStore.refreshAfterSourceChange` ile aynı gerekçe.
    public func refreshAfterKeyChange() async {
        guard isEnabled else { return }
        await performFetch()
    }

    /// Anahtar silindiğinde ekranda bayat bakiye bırakmamak için.
    public func clear() {
        balance = nil
        errorMessage = nil
        hasLoadedOnce = false
        lastAttemptAt = nil
    }

    private func performFetch() async {
        isLoading = true
        hasLoadedOnce = true
        lastAttemptAt = now()
        defer { isLoading = false }
        do {
            balance = try await service.fetch()
            errorMessage = nil
        } catch let error as LumiError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
