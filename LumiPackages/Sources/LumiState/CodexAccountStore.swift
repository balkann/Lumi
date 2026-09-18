import LumiKit
import Observation

@Observable
@MainActor
public final class CodexAccountStore {
    public enum Activity: Equatable, Sendable {
        case idle
        case adding
        case reauthenticating(accountID: String)
        case removing(accountID: String)
        case switching(to: CodexAccountSelection)
    }

    public private(set) var accounts: [CodexAccount] = []
    public private(set) var selection: CodexAccountSelection = .systemDefault
    public private(set) var systemDefaultEmail: String?
    public private(set) var activity: Activity = .idle

    @ObservationIgnored private let service: any CodexAccountServicing
    @ObservationIgnored private let toasts: ToastStore
    @ObservationIgnored private let onSelectionChanged: @MainActor (String) -> Void

    public init(
        service: any CodexAccountServicing,
        toasts: ToastStore,
        onSelectionChanged: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.service = service
        self.toasts = toasts
        self.onSelectionChanged = onSelectionChanged
    }

    public var isBusy: Bool { activity != .idle }
    public var isSigningIn: Bool {
        if case .reauthenticating = activity { return true }
        return activity == .adding
    }
    public var activeAccount: CodexAccount? {
        selection.accountID.flatMap { id in accounts.first { $0.id == id } }
    }
    public var activeLabel: String { activeAccount?.email ?? systemDefaultEmail ?? "System default" }
    public func isActive(_ value: CodexAccountSelection) -> Bool { selection == value }

    public func load() async {
        apply(await service.accounts())
        onSelectionChanged(await service.selectedHome())
    }

    public func addAccount() async {
        let succeeded = await run(.adding) { [service] in try await service.addAccount() }
        guard succeeded else { return }
        await selectionDidChange(title: "Account added")
    }

    public func cancelPendingLogin() async {
        guard isSigningIn else { return }
        await service.cancelPendingLogin()
    }

    public func reauthenticate(_ account: CodexAccount) async {
        _ = await run(.reauthenticating(accountID: account.id)) { [service] in
            try await service.reauthenticate(accountID: account.id)
        }
    }

    public func removeAccount(_ account: CodexAccount) async {
        let wasActive = selection == .account(account.id)
        let succeeded = await run(.removing(accountID: account.id)) { [service] in
            try await service.removeAccount(accountID: account.id)
        }
        guard succeeded else { return }
        if wasActive { await selectionDidChange(title: "Account removed") }
        else { toasts.show(.info, title: "Account removed", message: "\(account.email) was removed.") }
    }

    public func select(_ value: CodexAccountSelection) async {
        guard value != selection else { return }
        let succeeded = await run(.switching(to: value)) { [service] in
            try await service.select(value)
        }
        guard succeeded else { return }
        await selectionDidChange(title: "Switched to \(activeLabel)")
    }

    private func selectionDidChange(title: String) async {
        onSelectionChanged(await service.selectedHome())
        toasts.show(
            .success,
            title: title,
            message: "New Codex terminals will use this account. Running terminals keep their current account."
        )
    }

    @discardableResult
    private func run(
        _ activity: Activity,
        _ operation: @escaping @MainActor () async throws -> CodexAccountsSnapshot
    ) async -> Bool {
        guard !isBusy else { return false }
        self.activity = activity
        defer { self.activity = .idle }
        return await toasts.reporting { [weak self] in self?.apply(try await operation()) }
    }

    private func apply(_ snapshot: CodexAccountsSnapshot) {
        accounts = snapshot.accounts
        selection = snapshot.selection
        systemDefaultEmail = snapshot.systemDefaultEmail
    }
}
