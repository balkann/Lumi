import SwiftUI
import LumiMobileKit

@main
struct LumiMobileApp: App {
    @State private var model = AppModel(client: RelayClient(), store: KeychainStore())

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task { await model.start() }
                .onOpenURL { url in
                    Task { await model.pair(from: url.absoluteString) }
                }
        }
    }
}
