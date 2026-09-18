import SwiftUI
import LumiMobileKit

/// Yeni chat oturumu başlatır (chat-first; telefon için saf kind=chat akışı).
/// Persona ve ilk prompt bu fazda kapsam dışı — yalnız repo seçimi yeterli.
struct NewSessionView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var repoPath = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("Repo", selection: $repoPath) {
                    Text("Seç…").tag("")
                    ForEach(model.repos) { repo in
                        Text(repo.name).tag(repo.path)
                    }
                }

                Section {
                    Button(action: submit) {
                        if model.startState == .sending {
                            ProgressView()
                        } else {
                            Text("Chat başlat")
                        }
                    }
                    .disabled(!canSubmit)
                    if case .failed(let error) = model.startState {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Yeni chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Vazgeç") { dismiss() }
                }
            }
            .onChange(of: model.startState) { _, state in
                if state == .succeeded {
                    model.resetStartState()
                    dismiss()
                }
            }
            .onAppear { model.resetStartState() }
        }
    }

    private var canSubmit: Bool {
        // Repo listesi Mac'ten `repos`/`welcome` ile gelir; Mac çevrimdışıysa buton pasif.
        model.macOnline
            && !model.repos.isEmpty
            && !repoPath.isEmpty
            && model.startState != .sending
    }

    private func submit() {
        Task {
            await model.startChatSession(repoPath: repoPath)
        }
    }
}
