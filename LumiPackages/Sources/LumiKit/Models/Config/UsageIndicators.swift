import Foundation

/// Topbar'daki sağlayıcı kullanım göstergelerinin açık/kapalı durumu
/// (`~/.lumi/config.json` → `usageIndicators`, karar 32). Kapalı sağlayıcı için
/// topbar'da buton çıkmaz ve HİÇBİR istek atılmaz — ne manuel ne otomatik.
/// Default claude açık (mevcut davranışın korunması), codex kapalı.
///
/// **Persistence yalnız `ConfigCodec` üzerinden — karar 9.**
public struct UsageIndicators: Sendable, Equatable {
    public var claude: Bool
    public var codex: Bool
    /// DeepSeek BAKİYE göstergesi (karar 75). Sağlayıcı listesinin dışındadır:
    /// DeepSeek bir `AgentProvider` değil, Claude Code'un yönlendirildiği bir
    /// endpoint'tir (karar 54) ve gösterdiği şey kullanım yüzdesi değil paradır.
    /// Varsayılan kapalı; anahtar kurulu değilse zaten hiç çizilmez.
    public var deepseek: Bool

    public static let defaults = UsageIndicators(claude: true, codex: false, deepseek: false)

    public init(claude: Bool, codex: Bool, deepseek: Bool = false) {
        self.claude = claude
        self.codex = codex
        self.deepseek = deepseek
    }

    public func isEnabled(_ provider: AgentProvider) -> Bool {
        switch provider {
        case .claude: return claude
        case .codex: return codex
        }
    }

    /// Immutable setter — mevcut değeri değiştirmez, yeni kopya döner.
    public func setting(_ enabled: Bool, for provider: AgentProvider) -> UsageIndicators {
        switch provider {
        case .claude: return UsageIndicators(claude: enabled, codex: codex, deepseek: deepseek)
        case .codex: return UsageIndicators(claude: claude, codex: enabled, deepseek: deepseek)
        }
    }

    /// DeepSeek göstergesinin immutable setter'ı (sağlayıcı ekseninden ayrı).
    public func settingDeepSeek(_ enabled: Bool) -> UsageIndicators {
        UsageIndicators(claude: claude, codex: codex, deepseek: enabled)
    }

    /// Topbar'ın çizeceği göstergeler — `AgentProvider.allCases` sırasında.
    public var enabledProviders: [AgentProvider] {
        AgentProvider.allCases.filter(isEnabled)
    }
}

/// Kullanım göstergesinin otomatik tazelenmesi (`~/.lumi/config.json` →
/// `usageAutoRefresh`). VARSAYILAN AÇIK: göstergenin elle yenilenmeden bayat
/// kalması, göstergenin kendisini anlamsız kılıyordu. Kapatıldığında hiçbir
/// otomatik istek atılmaz. Açıkken `intervalMinutes`'te bir, YALNIZCA kullanıcı
/// aktifse (son HID girdisinden bu yana aralıktan az süre geçmişse) tazelenir;
/// Mac uykudayken process askıda olduğundan tetiklenmez.
///
/// Not: `enabled` anahtarı dosyaya zaten yazılmış kurulumlarda kayıtlı değer
/// kazanır — yeni varsayılan yalnız anahtarı olmayan config'lere uygulanır.
///
/// **Persistence yalnız `ConfigCodec` üzerinden — karar 9.**
public struct UsageAutoRefresh: Sendable, Equatable {
    public var enabled: Bool
    /// Tazeleme aralığı (dakika). Yalnız `allowedIntervals` değerleri geçerli;
    /// dışındaki değerler default'a düşer.
    public var intervalMinutes: Int

    /// UI'da sunulan ve kabul edilen aralık seçenekleri (K38 kararı A;
    /// karar 55 ile {5, 15, 30} → {1, 5}). 1 dk seçeneği TTL cache'ine (300 sn)
    /// takılmaz: otomatik döngü de kullanıcının manuel yenilemesi gibi
    /// `UsageStore.refresh()`'ten geçer ve cache'i açıkça geçersizler.
    public static let allowedIntervals = [1, 5]

    public static let defaults = UsageAutoRefresh(enabled: true, intervalMinutes: 5)

    /// Doğrulama sözleşmesi: izinli set dışındaki her değer (eski dosyalardaki
    /// `15`/`30` dahil) default'a clamp'lenir. Karar 9 ihlali DEĞİLDİR — bu tip zaten
    /// baştan beri doğrulayan bir init'e sahipti; yalnız izinli set daraldı.
    public init(enabled: Bool, intervalMinutes: Int) {
        self.enabled = enabled
        self.intervalMinutes = Self.allowedIntervals.contains(intervalMinutes)
            ? intervalMinutes
            : Self.defaults.intervalMinutes
    }
}
