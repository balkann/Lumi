import LumiKit
import LumiState
import SwiftUI

public struct CreateWorkspaceOverlay: View {
    @Shell private var shell
    let projectPath: String?
    @State private var selectedProject: Repo?
    @State private var formHeight: CGFloat = 1

    public init(projectPath: String? = nil) { self.projectPath = projectPath }

    private var effectiveProjectPath: String? {
        if let projectPath { return projectPath }
        guard case .createWorkspace(let path) = shell.dialogs.active else { return nil }
        return path
    }

    private var project: Repo? {
        selectedProject ?? effectiveProjectPath.flatMap { shell.repos.repo(at: $0) }
    }

    public var body: some View {
        GeometryReader { geometry in
            ModalOverlay(onDismiss: dismiss) {
                Panel(variant: .modal) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                        header
                        if let project {
                            projectPicker(project)
                            ScrollView {
                                form(project)
                                    .background(GeometryReader { content in
                                        Color.clear.preference(key: WorkspaceFormHeight.self, value: content.size.height)
                                    })
                            }
                            .onPreferenceChange(WorkspaceFormHeight.self) { height in
                                Task { @MainActor in formHeight = height }
                            }
                            .frame(height: min(formHeight, max(Self.minFormHeight, min(Self.maxFormHeight, geometry.size.height - Theme.Spacing.xxxl * 2) - Self.chromeHeight)))
                        } else {
                            Text("Project is no longer available.")
                                .font(Theme.Typography.bodyMono)
                                .foregroundStyle(Theme.textMuted)
                        }
                    }
                    .padding(Theme.Spacing.xxxl)
                    .frame(width: 520)
                }
            }
            .task(id: effectiveProjectPath) {
                guard let effectiveProjectPath else { return }
                guard let project = shell.repos.repo(at: effectiveProjectPath) else { return }
                selectedProject = project
                await shell.workspaces.selectProject(project)
            }
        }
    }

    /// Modal yüksekliği: form kendi boyunca sığıyorsa scroll yok. Tavan
    /// 680'di ve Cancel/Create butonları pencerede yer varken bile şeridin
    /// altında kalıyordu; başlık + proje seçici + paddingler için ayrılan pay
    /// da ölçüldü (32*2 padding + ~46 başlık + ~56 seçici + aralıklar).
    private static let maxFormHeight: CGFloat = 860
    private static let minFormHeight: CGFloat = 100
    private static let chromeHeight: CGFloat = 150

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text("Create workspace")
                    .font(Theme.Typography.titleMono)
                    .foregroundStyle(Theme.textPrimary)
                Text("Create a local workspace from this project")
                    .font(Theme.Typography.labelMono)
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer(minLength: 0)
            IconButton(systemName: "xmark", label: "Cancel", size: .body, side: Theme.Spacing.xxl, action: dismiss)
        }
    }

    private func projectPicker(_ project: Repo) -> some View {
        field("Project") {
            LumiDropdown(
                options: projectCandidates.map { .init(value: $0.path, label: $0.name) },
                selection: Binding(
                    get: { selectedProject?.path ?? project.path },
                    set: { path in
                        guard let next = projectCandidates.first(where: { $0.path == path }) else { return }
                        selectedProject = next
                        Task { await shell.workspaces.selectProject(next) }
                    }
                ),
                placeholder: project.name
            )
            .disabled(shell.workspaces.isCreating || shell.workspaces.lastCreated != nil)
        }
    }

    private var projectCandidates: [Repo] {
        shell.workspaces.addedProjects
    }

    private func form(_ project: Repo) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            field("Name") {
                LumiTextInput(text: binding(\.name), placeholder: "Workspace name", autofocus: true)
                    .disabled(shell.workspaces.lastCreated != nil)
            }
            field("Agent") {
                LumiDropdown(
                    options: WorkspaceAgent.allCases.map { .init(value: $0, label: $0.title) },
                    selection: binding(\.agent)
                )
            }
            if shell.workspaces.isInspecting {
                Label("Inspecting project…", systemImage: "hourglass")
                    .font(Theme.Typography.labelMono)
                    .foregroundStyle(Theme.textMuted)
            } else if let source = shell.workspaces.source {
                detected(source)
            }
            if shell.workspaces.source?.isUnityProject == true {
                unitySection.disabled(shell.workspaces.lastCreated != nil)
            }
            if let source = shell.workspaces.source, source.scm != .none {
                branchSection(source).disabled(shell.workspaces.lastCreated != nil)
            }
            destination
            if let message = shell.workspaces.errorMessage {
                Text(message).font(Theme.Typography.labelMono).foregroundStyle(Theme.error)
            }
            if let message = shell.workspaces.warningMessage {
                Text(message).font(Theme.Typography.labelMono).foregroundStyle(Theme.warning)
            }
            HStack(spacing: Theme.Spacing.md) {
                Spacer(minLength: 0)
                LumiActionButton(title: "Cancel", action: dismiss)
                LumiActionButton(title: shell.workspaces.phaseText, kind: .primary) {
                    shell.startWorkspaceCreation()
                }
                .disabled(!shell.workspaces.canCreate || shell.workspaces.isCreating)
            }
        }
        .disabled(shell.workspaces.isCreating)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title).font(Theme.Typography.labelMono).foregroundStyle(Theme.textSecondary)
            content()
        }
    }

    private func detected(_ source: WorkspaceSource) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Detected").font(Theme.Typography.labelMono).foregroundStyle(Theme.textSecondary)
            Text(source.scm == .none ? "Select a Git or Plastic SCM project to create a workspace." : "\(source.scm.title) detected · \(source.branch.isEmpty ? "detached HEAD" : source.branch)")
                .font(Theme.Typography.bodyMono).foregroundStyle(Theme.textPrimary)
        }
    }

    private var unitySection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Unity project detected").font(Theme.Typography.labelMono).foregroundStyle(Theme.textSecondary)
            Text("Copying Library may shorten the first Unity import for CLI/MCP workflows.")
                .font(Theme.Typography.labelMono).foregroundStyle(Theme.textMuted)
            HStack(spacing: Theme.Spacing.sm) {
                LumiToggleSwitch(isOn: binding(\.copyLibrary), label: "Copy Library")
                Text("Copy Library").font(Theme.Typography.bodyMono).foregroundStyle(Theme.textPrimary)
            }
                .disabled(shell.workspaces.source?.hasLibrary != true || shell.workspaces.source?.libraryCopyBlockedReason != nil)
                .opacity(shell.workspaces.source?.hasLibrary == true && shell.workspaces.source?.libraryCopyBlockedReason == nil ? 1 : 0.45)
            if let reason = shell.workspaces.source?.libraryCopyBlockedReason {
                Text(reason).font(Theme.Typography.labelMono).foregroundStyle(Theme.textMuted)
            }
            // Açık Unity artık engel değil (karar 58); yalnız uyarılır.
            if let warning = shell.workspaces.source?.libraryCopyWarning, shell.workspaces.copyLibrary {
                Text(warning).font(Theme.Typography.labelMono).foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Dal seçimi (karar 58)

    private func branchSection(_ source: WorkspaceSource) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            field("Branch") {
                LumiDropdown(
                    options: branchModes(source).map { .init(value: $0, label: $0.title) },
                    selection: binding(\.branchMode)
                )
            }
            switch shell.workspaces.branchMode {
            case .current:
                hint("Checks out \(source.branch.isEmpty ? "the current branch" : source.branch) in a separate workspace.")
            case .existing:
                branchList(placeholder: "Select a branch")
                LumiTextInput(text: binding(\.existingBranch), placeholder: "or type a branch path")
                hint("The list shows every branch, most recently updated first; type in the field to search.")
            case .new:
                // Taban önce: yeni dalın adı Plastic'te onun altında oluşur.
                field("Base branch") {
                    LumiDropdown(
                        options: baseBranchOptions(source),
                        selection: binding(\.baseBranch),
                        placeholder: "Current branch",
                        onOpen: loadBranches,
                        emptyNote: branchNote
                    )
                }
                field("Branch name") {
                    LumiTextInput(text: branchLeafBinding(source), placeholder: WorkspaceName.slug(shell.workspaces.name))
                }
                if source.scm == .plastic {
                    hint("Creates \(newBranchPath(source)) — the hierarchy comes from the base branch, so \"/\" is not allowed here.")
                }
            }
            if let error = shell.workspaces.branchListError {
                Text(error).font(Theme.Typography.labelMono).foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Liste dropdown açılmadan ÖNCE hazırlanır: mod seçimi zaten kullanıcının
        // dallara bakacağını söylüyor ve Plastic sorgusu ~1,5 sn sürüyor.
        .task(id: prefetchKey) {
            guard shell.workspaces.branchMode != .current else { return }
            await shell.workspaces.loadBranches()
        }
    }

    /// Proje ya da mod değişince listeyi yeniden hazırlar.
    private var prefetchKey: String {
        "\(shell.workspaces.selectedProjectPath ?? "")#\(shell.workspaces.branchMode.rawValue)"
    }

    /// Git aynı dalı ikinci bir worktree'de checkout edemez; "current" yalnız
    /// Plastic'te anlamlıdır.
    private func branchModes(_ source: WorkspaceSource) -> [WorkspaceBranchMode] {
        source.scm == .plastic ? [.current, .existing, .new] : [.existing, .new]
    }

    private func branchList(placeholder: String) -> some View {
        LumiDropdown(
            options: shell.workspaces.branches.map { .init(value: $0.name, label: $0.name) },
            selection: binding(\.existingBranch),
            placeholder: placeholder,
            onOpen: loadBranches,
            emptyNote: branchNote
        )
    }

    private func baseBranchOptions(_ source: WorkspaceSource) -> [LumiDropdown<String>.Option] {
        let current = LumiDropdown<String>.Option(
            value: "", label: source.branch.isEmpty ? "Current branch" : source.branch, detail: "current"
        )
        return [current] + shell.workspaces.branches
            .filter { $0.name != source.branch }
            .map { .init(value: $0.name, label: $0.name) }
    }

    /// Plastic'te dal adı tek parçadır; yazılan "/" karakterleri düşürülür.
    private func branchLeafBinding(_ source: WorkspaceSource) -> Binding<String> {
        let stored = binding(\.branchName)
        guard source.scm == .plastic else { return stored }
        return Binding(
            get: { stored.wrappedValue },
            set: { stored.wrappedValue = $0.replacingOccurrences(of: "/", with: "") }
        )
    }

    private func newBranchPath(_ source: WorkspaceSource) -> String {
        let typed = shell.workspaces.branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        let leaf = typed.isEmpty ? WorkspaceName.slug(shell.workspaces.name) : typed
        let base = shell.workspaces.baseBranch
        return source.fullBranch(leaf: leaf.isEmpty ? "…" : leaf, base: base.isEmpty ? nil : base)
    }

    private var branchNote: String {
        if shell.workspaces.isLoadingBranches { return "Loading branches…" }
        if let error = shell.workspaces.branchListError { return error }
        return "No branches found"
    }

    private func loadBranches() {
        Task { await shell.workspaces.loadBranches() }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.labelMono)
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Eskiden "Advanced" disclosure'ıydı; içinde yalnız taban revizyon ve tek
    /// cümlelik açıklama vardı, açılıp kapanmaya değmiyordu (kullanıcı isteği).
    private var destination: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Destination: \(shell.workspaces.destinationPath)")
                .font(Theme.Typography.labelMono).foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            hint(shell.workspaces.branchMode == .new
                ? "Starts from the selected base branch's latest commit or changeset. Uncommitted changes are not copied."
                : "Checks out the selected branch in a separate workspace. Uncommitted changes are not copied.")
        }
    }

    private func binding<Value>(_ keyPath: ReferenceWritableKeyPath<ProjectWorkspaceStore, Value>) -> Binding<Value> {
        Binding(get: { shell.workspaces[keyPath: keyPath] }, set: { shell.workspaces[keyPath: keyPath] = $0 })
    }

    private func dismiss() {
        guard !shell.workspaces.isCreating else { return }
        shell.workspaces.clearForm()
        if let effectiveProjectPath {
            shell.dialogs.dismiss(.createWorkspace(projectPath: effectiveProjectPath))
        } else {
            shell.dialogs.dismiss()
        }
    }
}

private struct WorkspaceFormHeight: PreferenceKey {
    static let defaultValue: CGFloat = 1
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

#if DEBUG
#Preview("CreateWorkspaceOverlay") {
    CreateWorkspaceOverlay(projectPath: "/Users/preview/Projects/lumi")
        .environment(\.shell, ShellContext.preview())
        .frame(width: 800, height: 600)
}
#endif
