import Foundation

/// Relay istemcisinin servis sınırı. Implementasyon LumiRemote'ta;
/// LumiUI yalnız bu protokolü (RemoteStore üzerinden) görür.
@MainActor
public protocol RemoteServicing: AnyObject, Sendable {
    var state: RemoteConnectionState { get }
    var currentConfig: RemoteConfig { get }
    /// Config'i günceller, diske yazar; enabled değiştiyse bağlantıyı açar/kapar.
    func updateConfig(_ mutate: @Sendable (inout RemoteConfig) -> Void) async
    /// Yeni token üretip kaydeder ve (bağlıysa) yeniden bağlanır.
    func regenerateToken() async
    func start() async
    func stop()
    func events() -> AsyncStream<RemoteEvent>
}
