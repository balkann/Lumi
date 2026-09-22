import LumiKit

/// `TranscriptLocating` no-op'u: `RemoteService` default'u — üretimde
/// `RemoteFeatureAssembly` gerçek `TranscriptLocator`'ı enjekte eder; bu
/// default yalnız transcript bulunamayan ortamlarda (veya testlerde locator
/// gerekmediğinde) kullanılır. Her zaman `nil` döner.
public struct NoopTranscriptLocating: TranscriptLocating {
    public init() {}
    public func locate(repoPath: String) -> String? { nil }
}
