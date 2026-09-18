import Foundation
import LumiKit

/// Mirrors non-secret runtime files into an isolated managed CODEX_HOME.
struct CodexManagedRuntimeResources {
    let systemHome: URL
    let hookScriptPath: String

    func materialize(into home: URL, hooksEnabled: Bool) throws {
        try mirrorConfig(into: home)
        try syncHooks(into: home, enabled: hooksEnabled)
    }

    private func mirrorConfig(into home: URL) throws {
        let source = systemHome.appendingPathComponent("config.toml")
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let data = try Data(contentsOf: source)
        guard !data.isEmpty else { return }
        try data.write(to: home.appendingPathComponent("config.toml"), options: .atomic)
    }

    /// Trust keys are path-bound, so managed groups are keyed for this home.
    func syncHooks(into home: URL, enabled: Bool) throws {
        let hooksURL = home.appendingPathComponent("hooks.json")
        let data = FileManager.default.contents(atPath: hooksURL.path) ?? Data("{}".utf8)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let command = AgentHookScript.managedCommand(scriptPath: hookScriptPath, provider: .codex)
        let applied = enabled ? CodexHookSettings.applyManaged(to: root, command: command) : nil
        let next = applied?.root ?? CodexHookSettings.removeManaged(from: root).root
        let output = try JSONSerialization.data(
            withJSONObject: next,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) + Data("\n".utf8)
        try output.write(to: hooksURL, options: .atomic)

        let hooksPath = home.resolvingSymlinksInPath().appendingPathComponent("hooks.json").path
        let entries = enabled ? CodexHookSettings.events.compactMap { event -> CodexHookTrust.Entry? in
            guard let label = CodexHookTrust.eventLabels[event],
                  let group = applied?.groupIndex[event] else { return nil }
            return CodexHookTrust.Entry(
                key: CodexHookTrust.key(hooksPath: hooksPath, label: label, group: group),
                hash: CodexHookTrust.trustedHash(
                    label: label, command: command, timeoutSeconds: CodexHookSettings.timeoutSeconds
                )
            )
        } : []
        let configURL = home.appendingPathComponent("config.toml")
        let sourceConfig = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let owned = Set(CodexHookTrust.eventLabels.values.map {
            CodexHookTrust.trustedHash(
                label: $0, command: command, timeoutSeconds: CodexHookSettings.timeoutSeconds
            )
        })
        let (result, changed) = CodexConfigTomlEditor.apply(
            to: sourceConfig, desired: entries, ownedHashes: owned
        )
        if changed { try result.write(to: configURL, atomically: true, encoding: .utf8) }
    }
}
