import SwiftUI
import LumiMobileKit

struct PairingView: View {
    let model: AppModel
    @State private var pastedLink = ""
    @State private var showError = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Mac'te Lumi → Ayarlar → Remote ekranındaki QR'ı okut ya da eşleştirme bağlantısını yapıştır.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                scannerSection
                Section("Bağlantıyı yapıştır") {
                    TextField("lumi-remote://pair?...", text: $pastedLink)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("pairingField")
                    Button("Eşleştir") {
                        Task {
                            let ok = await model.pair(from: pastedLink)
                            showError = !ok
                        }
                    }
                    .accessibilityIdentifier("pairButton")
                    .disabled(pastedLink.isEmpty)
                    if showError {
                        Text("Bağlantı çözümlenemedi. `lumi-remote://pair?...` biçiminde olmalı.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Eşleştirme")
        }
    }

    @ViewBuilder private var scannerSection: some View {
        if QRScannerView.isAvailable {
            Section("QR okut") {
                QRScannerView { value in
                    Task {
                        let ok = await model.pair(from: value)
                        showError = !ok
                    }
                }
                .frame(height: 260)
                .listRowInsets(EdgeInsets())
            }
        }
    }
}
