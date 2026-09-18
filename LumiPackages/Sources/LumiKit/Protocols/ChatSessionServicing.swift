import Foundation

/// Chat oturumlarını (stream-json chat lane) yöneten yüz. Her oturum bir
/// `StreamJsonAgentSession`'a karşılık gelir; UI/wire katmanı bu protokolü görür
/// (spec Yol B Faz 2 §A). Chat oturumları in-memory tutulur; geçmiş claude
/// transcript'inde kalıcıdır.
public protocol ChatSessionServicing: Sendable {
    /// Yeni chat oturumu oluşturur (yeni session-id + child spawn + start) ve
    /// meta'sını döndürür.
    @discardableResult func create(repoPath: String) async -> ChatSessionMeta
    /// Açık chat oturumlarının meta listesi.
    func list() async -> [ChatSessionMeta]
    /// Oturumu durdurur ve kayıttan düşürür.
    func close(id: String) async
    /// Kullanıcı mesajını oturumun stream-json stdin'ine yollar.
    func send(id: String, text: String) async
    /// Oturumun journal durum akışı; oturum yoksa nil.
    func snapshots(id: String) async -> AsyncStream<ChatJournalState>?
}
