import SwiftUI
import LumiMobileKit

@main
struct LumiMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    private let coordinator: PushCoordinator

    init() {
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
