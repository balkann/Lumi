import Foundation

public enum WorkspaceSCM: String, Sendable, Equatable, CaseIterable {
    case git, plastic, none

    public var title: String {
        switch self {
        case .git: "Git"
        case .plastic: "Plastic SCM"
        case .none: "Folder"
        }
    }
}

public struct ProjectWorkspace: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let projectPath: String
    public let path: String
    public let name: String
    public let branch: String
    public let scm: WorkspaceSCM

    public init(projectPath: String, path: String, name: String, branch: String, scm: WorkspaceSCM) {
        self.projectPath = projectPath
        self.path = path
        self.name = name
        self.branch = branch
        self.scm = scm
    }

    public var repo: Repo {
        Repo(name: name, path: path, isGitRepo: scm == .git, source: .standalone)
    }
}

public struct WorkspaceSource: Sendable, Equatable {
    public let projectPath: String
    public let scm: WorkspaceSCM
    public let branch: String
    public let revision: String
    public let repositorySpec: String?
    public let destinationDirectory: String
    public let isUnityProject: Bool
    public let hasLibrary: Bool
    public let libraryCopyBlockedReason: String?
    /// Kopyalamayı engellemeyen ama sonucu etkileyebilecek durum (açık Unity
    /// Editor'ü): kullanıcı yine de kopyalayabilir, Library yeniden üretilebilir
    /// bir önbellektir (karar 58).
    public let libraryCopyWarning: String?

    public init(
        projectPath: String, scm: WorkspaceSCM, branch: String = "", revision: String = "",
        repositorySpec: String? = nil, destinationDirectory: String,
        isUnityProject: Bool = false, hasLibrary: Bool = false,
        libraryCopyBlockedReason: String? = nil,
        libraryCopyWarning: String? = nil
    ) {
        self.projectPath = projectPath
        self.scm = scm
        self.branch = branch
        self.revision = revision
        self.repositorySpec = repositorySpec
        self.destinationDirectory = destinationDirectory
        self.isUnityProject = isUnityProject
        self.hasLibrary = hasLibrary
        self.libraryCopyBlockedReason = libraryCopyBlockedReason
        self.libraryCopyWarning = libraryCopyWarning
    }

    /// Yeni dal adı önerisi. `base` verilirse yeni dal o dalın altında önerilir
    /// (Plastic'te dal adı hiyerarşiyi taşır).
    public func suggestedBranch(name: String, base: String? = nil) -> String {
        let slug = WorkspaceName.slug(name)
        guard scm == .plastic else { return slug }
        let parent = (base?.isEmpty == false ? base! : branch)
        return "\(parent.isEmpty ? "/main" : parent)/\(slug)"
    }
}

public enum WorkspaceName {
    public static func slug(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let parts = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: allowed.inverted).filter { !$0.isEmpty }
        return parts.joined(separator: "-").trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
    }
}

/// Workspace'in hangi dalda açılacağı (karar 58).
public enum WorkspaceBranchMode: String, Sendable, Equatable, CaseIterable {
    /// Projenin şu an bulunduğu dal.
    case current
    /// Sunucudaki mevcut bir dal (listeden seçilir veya elle yazılır).
    case existing
    /// Yeni dal; `baseBranch` verilmezse mevcut daldan çıkar.
    case new

    public var title: String {
        switch self {
        case .current: "Current branch"
        case .existing: "Existing branch"
        case .new: "New branch"
        }
    }
}

/// Dal listesi satırı (karar 58); liste en son değişen dal başta gelir.
public struct WorkspaceBranch: Sendable, Equatable, Identifiable {
    public let name: String

    public init(name: String) { self.name = name }

    public var id: String { name }
}

public struct WorkspaceCreateRequest: Sendable {
    public let project: Repo
    public let name: String
    /// `.new` modunda yeni dalın adı, `.existing` modunda seçilen dal.
    public let branchName: String?
    public let branchMode: WorkspaceBranchMode
    /// Yalnız `.new` modunda: yeni dalın çıkacağı dal (nil → mevcut dal).
    public let baseBranch: String?
    public let copyLibrary: Bool
    public let knownProjectPaths: [String]

    public init(
        project: Repo, name: String, branchName: String? = nil,
        branchMode: WorkspaceBranchMode = .new, baseBranch: String? = nil,
        copyLibrary: Bool = false, knownProjectPaths: [String] = []
    ) {
        self.project = project
        self.name = name
        self.branchName = branchName
        self.branchMode = branchMode
        self.baseBranch = baseBranch
        self.copyLibrary = copyLibrary
        self.knownProjectPaths = knownProjectPaths
    }

    public var createNewBranch: Bool { branchMode == .new }
}

public struct WorkspaceCreateResult: Sendable, Equatable {
    public let workspace: ProjectWorkspace
    public let warning: String?

    public init(workspace: ProjectWorkspace, warning: String? = nil) {
        self.workspace = workspace
        self.warning = warning
    }
}

public enum WorkspaceAgent: String, CaseIterable, Sendable {
    case claude, codex, shell, none

    public var title: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .shell: "Shell"
        case .none: "Don't start a session"
        }
    }

    public var command: String? {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .shell, .none: nil
        }
    }
}

public struct WorkspaceFailure: LocalizedError, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
