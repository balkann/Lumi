import SwiftUI
import LumiMobileKit

struct NewSessionView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var repoPath = ""
    @State private var branchMode = "current"          // current | existing | new
    @State private var selectedBranch = ""
    @State private var newBranchName = ""
    @State private var baseBranch = ""
    @State private var workspaceName = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("Repo", selection: $repoPath) {
                    Text("Seç…").tag("")
                    ForEach(model.repos) { repo in Text(repo.name).tag(repo.path) }
                }
                .onChange(of: repoPath) { _, path in
                    resetBranchFields()
                    if !path.isEmpty { Task { await model.loadBranches(repoPath: path) } }
                }

                if !repoPath.isEmpty {
                    Picker("Dal", selection: $branchMode) {
                        Text("Mevcut dal").tag("current")
                        Text("Var olan dal").tag("existing")
                        Text("Yeni dal").tag("new")
                    }
                    .pickerStyle(.segmented)

                    if branchMode == "existing" {
                        if model.branchesLoading {
                            HStack { ProgressView(); Text("Dallar yükleniyor…") }
                        } else if let err = model.branchesError {
                            Text(err).font(.footnote).foregroundStyle(.orange)
                        } else {
                            Picker("Dal", selection: $selectedBranch) {
                                Text("Seç…").tag("")
                                ForEach(model.branchesForRepo, id: \.self) { Text($0).tag($0) }
                            }
                        }
                    } else if branchMode == "new" {
                        TextField("Yeni dal adı", text: $newBranchName)
                            .autocorrectionDisabled()
                        Picker("Baz dal (ops.)", selection: $baseBranch) {
                            Text("Mevcut dal").tag("")
                            ForEach(model.branchesForRepo, id: \.self) { Text($0).tag($0) }
                        }
                    }

                    if branchMode != "current" {
                        TextField("Workspace adı (ops.)", text: $workspaceName)
                            .autocorrectionDisabled()
                    }
                }

                Section {
                    Button(action: submit) {
                        if model.startState == .sending { ProgressView() }
                        else { Text("Chat başlat") }
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
                if state == .succeeded { model.resetStartState(); dismiss() }
            }
            .onAppear { model.resetStartState() }
        }
    }

    private var canSubmit: Bool {
        guard model.macOnline, !model.repos.isEmpty, !repoPath.isEmpty,
              model.startState != .sending else { return false }
        switch branchMode {
        case "existing": return !selectedBranch.isEmpty
        case "new": return !newBranchName.trimmingCharacters(in: .whitespaces).isEmpty
        default: return true
        }
    }

    private func resetBranchFields() {
        branchMode = "current"; selectedBranch = ""; newBranchName = ""
        baseBranch = ""; workspaceName = ""
    }

    private func submit() {
        Task {
            switch branchMode {
            case "existing":
                await model.startChatSession(repoPath: repoPath, branchMode: "existing",
                    branchName: selectedBranch, workspaceName: workspaceName.isEmpty ? nil : workspaceName)
            case "new":
                await model.startChatSession(repoPath: repoPath, branchMode: "new",
                    branchName: newBranchName, baseBranch: baseBranch.isEmpty ? nil : baseBranch,
                    workspaceName: workspaceName.isEmpty ? nil : workspaceName)
            default:
                await model.startChatSession(repoPath: repoPath)
            }
        }
    }
}
