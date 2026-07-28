import SwiftUI
import LumiMobileKit

struct NewSessionView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var repoPath = ""
    @State private var personaId = ""
    @State private var prompt = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("Repo", selection: $repoPath) {
                    Text("Seç…").tag("")
                    ForEach(model.repos) { repo in
                        Text(repo.name).tag(repo.path)
                    }
                }
                Picker("Persona", selection: $personaId) {
                    Text("Yok").tag("")
                    ForEach(model.personas) { persona in
                        Text(persona.label).tag(persona.id)
                    }
                }
                TextField("İlk prompt", text: $prompt, axis: .vertical)
                    .lineLimit(3...8)

                Section {
                    Button(action: submit) {
                        if model.startState == .sending {
                            ProgressView()
                        } else {
                            Text("Oturumu başlat")
                        }
                    }
                    .disabled(!canSubmit)
                    if case .failed(let error) = model.startState {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Yeni oturum")
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
        model.macOnline
            && !repoPath.isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.startState != .sending
    }

    private func submit() {
        Task {
            await model.startSession(
                repoPath: repoPath,
                personaId: personaId.isEmpty ? nil : personaId,
                prompt: prompt
            )
        }
    }
}
