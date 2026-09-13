import SwiftUI
import LumiMobileKit

@main
struct LumiMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    private let coordinator: PushCoordinator

    init() {
        // Kalıcı teşhis günlüğü — Documents/lumi-mobile.log; Mac'ten
        // `xcrun devicectl device copy from` ile çekilip incelenir.
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            DiagLog.shared.configure(directory: docs, filename: "lumi-mobile.log")
        }
        DiagLog.shared.log("app", "başlatıldı")
        let model = AppModel(client: RelayClient(), store: KeychainStore())
        let coordinator = PushCoordinator(
            model: model,
            authorizer: SystemNotificationAuthorizer(),
            registrar: SystemRemoteRegistrar()
        )
        model.pushControl = coordinator
        _model = State(initialValue: model)
        self.coordinator = coordinator
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task {
                    appDelegate.coordinator = coordinator
                    await coordinator.refreshAuthStatus()
                    await model.start()
                }
                .onOpenURL { url in
                    Task { await model.pair(from: url.absoluteString) }
                }
        }
    }
}
