/// Dış/taze oturumlar için repo yolundan en yeni transcript oturum kimliğini bulan sınır.
/// LumiRemote yalnız LumiKit'e bağlı olduğu için protocol buraya taşındı;
/// canlı uygulama LumiServices.TranscriptLocator, testlerde FakeTranscriptLocating.
public protocol TranscriptLocating: Sendable {
    /// Verilen repo yolundaki en yeni Claude transcript oturum kimliğini döner; bulamazsa nil.
    func locate(repoPath: String) -> String?
}
