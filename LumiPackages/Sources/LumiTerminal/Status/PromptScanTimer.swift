import Foundation

/// Ekran-scrape tetikleyicisi: çıktı `interval` boyunca durunca onDue (spec 4 §2/K2).
/// CodexSilenceTimer'ın kardeşi ama daha kısa; provider'dan bağımsız her çıktıda touch edilir.
final class PromptScanTimer {
    static let defaultInterval: TimeInterval = 0.35

    var onDue: (() -> Void)?
    private let scheduler: OneShotScheduling
    private let interval: TimeInterval

    init(scheduler: OneShotScheduling, interval: TimeInterval = PromptScanTimer.defaultInterval) {
        self.scheduler = scheduler
        self.interval = interval
    }

    func touch() {
        scheduler.schedule(after: interval) { [weak self] in
            self?.onDue?()
        }
    }

    func cancel() {
        scheduler.cancel()
    }
}
