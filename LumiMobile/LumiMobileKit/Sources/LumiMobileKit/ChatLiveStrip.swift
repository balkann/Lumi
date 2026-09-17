/// Chat ekranındaki canlı terminal şeridinin görünürlük kuralı (spec 2026-09-17):
/// turn çalışıyor VEYA cevapsız prompt var — ve bu oturumdan en az bir feed
/// chunk'ı gelmiş (dış/PTY'siz oturumda şerit hiç görünmez).
public func chatLiveStripVisible(working: Bool, hasPendingPrompt: Bool, hasFeed: Bool) -> Bool {
    (working || hasPendingPrompt) && hasFeed
}
