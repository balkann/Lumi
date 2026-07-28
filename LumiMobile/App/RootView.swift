import SwiftUI
import LumiMobileKit

struct RootView: View {
    let model: AppModel

    var body: some View {
        if model.isPaired {
            SessionListView(model: model)
        } else {
            PairingView(model: model)
        }
    }
}

// Task 6'da gerçek listeyle değiştirilecek geçici görünüm.
struct SessionListView: View {
    let model: AppModel

    var body: some View {
        NavigationStack {
            Text("Eşleşti — oturum listesi Task 6'da")
                .navigationTitle("Lumi")
        }
    }
}
