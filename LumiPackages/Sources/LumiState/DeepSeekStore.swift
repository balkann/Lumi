import Foundation
import LumiKit
import Observation

/// Settings ▸ Agent ▸ DeepSeek durumu (karar 54).
///
/// Diskteki env dosyası tek gerçek kaynaktır; store onun okunmuş hâlini
/// (`setup`) ve kullanıcının yazdığı taslak anahtarı (`apiKeyDraft`) taşır.
/// Terminal açma yolu da buradan beslenir: `launchCommand` nil ise dropdown
/// DeepSeek'i açmayı reddeder ve kullanıcıyı ayarlara yönlendirir.
@Observable
@MainActor
public final class DeepSeekStore {
    @ObservationIgnored private let service: any DeepSeekEnvironmentServicing
    @ObservationIgnored private let toasts: ToastStore

    public private(set) var setup: DeepSeekSetup?
    public private(set) var isBusy = false
    /// Alanın içeriği — kurulu anahtar yüklendiğinde onunla başlar.
    public var apiKeyDraft = ""

    public init(service: any DeepSeekEnvironmentServicing, toasts: ToastStore) {
        self.service = service
        self.toasts = toasts
    }

    // MARK: - Türevler

    public var isInstalled: Bool { setup?.isInstalled ?? false }
    public var envFilePath: String? { setup?.envFilePath }
    public var launchCommand: String? { setup?.launchCommand }

    public var canInstall: Bool {
        !isBusy && DeepSeekEnvironment.isValidAPIKey(apiKeyDraft)
    }

    /// Alandaki anahtar diskteki anahtardan farklı = kaydedilmemiş değişiklik.
    public var hasUnsavedKey: Bool {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed != setup?.apiKey
    }

    // MARK: - Eylemler

    public func load() async {
        let value = await service.read()
        setup = value
        if apiKeyDraft.isEmpty, let key = value.apiKey {
            apiKeyDraft = key
        }
    }

    /// Env dosyasını yazar. Başarıda `setup` tazelenir ve toast gösterilir.
    public func install() async {
        guard canInstall else { return }
        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        isBusy = true
        defer { isBusy = false }
        let installed = await toasts.reporting { [service] in
            let value = try await service.install(apiKey: key)
            self.setup = value
        }
        guard installed else { return }
        toasts.show(
            .success,
            title: "DeepSeek ready",
            message: "New DeepSeek terminals will use api.deepseek.com."
        )
    }

    public func remove() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let removed = await toasts.reporting { [service] in
            let value = try await service.remove()
            self.setup = value
        }
        guard removed else { return }
        apiKeyDraft = ""
        toasts.show(.info, title: "DeepSeek removed", message: "Claude runs on your Anthropic plan again.")
    }

    /// Dropdown DeepSeek terminali isterken çağırır; kurulu değilse kullanıcıya
    /// nedenini söyler ve `nil` döner.
    public func launchCommandOrWarn() -> String? {
        if let command = launchCommand { return command }
        toasts.show(
            .info,
            title: "DeepSeek not configured",
            message: "Add your API key in Settings ▸ Agent first."
        )
        return nil
    }
}
