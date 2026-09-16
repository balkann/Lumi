import Foundation

/// Ortamı ve akış davranışı ayarlanabilen süreç sınırı (karar 56).
///
/// `ProcessRunning`'den ayrı bir protokoldür (ISP): tüm çağrı yerlerine env
/// parametresi eklemek yerine, gerçekten ihtiyacı olan tek akış — `claude auth
/// login`'i yalıtılmış bir `CLAUDE_CONFIG_DIR` altında koşturmak — kendi dar
/// sınırını alır.
///
/// Sessiz-fail sözleşmesi `ProcessRunning` ile aynıdır: timeout, başlatma
/// hatası ya da iptal `nil` döndürür.
public protocol EnvironmentProcessRunning: Sendable {
    func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String],
        options: ProcessLaunchOptions,
        timeout: TimeInterval
    ) async -> ProcessOutput?
}

extension EnvironmentProcessRunning {
    public func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) async -> ProcessOutput? {
        await run(
            executable, arguments: arguments, environment: environment,
            options: .default, timeout: timeout
        )
    }
}

/// Uzun soluklu, etkileşimli bir alt sürecin davranış ayarları (karar 56).
public struct ProcessLaunchOptions: Sendable {
    /// stdin'i AÇIK bir pipe olarak tutar (veri yazılmaz).
    ///
    /// Claude'un tarayıcı tabanlı auth akışı, yerel callback sunucusunun
    /// ömrünü stdin'e bağlayabiliyor; `.app` içinde stdin `/dev/null` olduğu
    /// için sunucu tarayıcı dönmeden kapanabilirdi.
    public var keepsStandardInputOpen: Bool
    /// Biriken çıktıyla çağrılır; `true` dönerse süreç hemen sonlandırılır.
    /// Kullanıcı tarayıcıda "Deny" dediğinde 180 sn'lik timeout'u beklememek
    /// için.
    public var shouldTerminateOnOutput: (@Sendable (String) -> Bool)?
    /// Sonlandırmada çocuğun ALT süreçlerini de öldürmeye çalışır (en iyi
    /// çaba): `claude` kendi alt süreçlerini bırakırsa OAuth callback portu
    /// açık kalır ve ikinci login denemesi düşerdi.
    public var terminatesChildProcesses: Bool

    public init(
        keepsStandardInputOpen: Bool = false,
        shouldTerminateOnOutput: (@Sendable (String) -> Bool)? = nil,
        terminatesChildProcesses: Bool = false
    ) {
        self.keepsStandardInputOpen = keepsStandardInputOpen
        self.shouldTerminateOnOutput = shouldTerminateOnOutput
        self.terminatesChildProcesses = terminatesChildProcesses
    }

    public static let `default` = ProcessLaunchOptions()
}
