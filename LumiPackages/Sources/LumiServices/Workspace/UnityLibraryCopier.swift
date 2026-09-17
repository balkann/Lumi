import Darwin
import Foundation
import LumiKit

/// Copies Unity's regenerable Library cache without sharing filesystem links.
/// The copy is staged inside the already-created workspace and installed with
/// one move, so a failed copy cannot replace an existing Library.
public struct UnityLibraryCopier: Sendable {
    public init() {}

    /// Kopyalamayı gerçekten imkânsız kılan durum. Açık bir Unity Editor'ü
    /// artık engel DEĞİL (karar 58): Library yeniden üretilebilir bir
    /// önbellektir, o yüzden yalnız uyarılır (`activeEditorWarning`).
    public func blockedReason(sourcePath: String) -> String? {
        isDirectory(URL(fileURLWithPath: sourcePath).appendingPathComponent("Library")) ? nil : "Library is unavailable"
    }

    /// Kaynak projede Unity açık görünüyorsa dönen açıklama; kopyalama yine de
    /// yapılabilir, Unity ilk açılışta tutarsız kalan parçaları yeniden üretir.
    public func activeEditorWarning(sourcePath: String) -> String? {
        let library = URL(fileURLWithPath: sourcePath).appendingPathComponent("Library")
        guard isDirectory(library) else { return nil }
        let temp = URL(fileURLWithPath: sourcePath).appendingPathComponent("Temp")
        if FileManager.default.fileExists(atPath: temp.appendingPathComponent("UnityLockfile").path) {
            return "Unity appears to be open (Temp/UnityLockfile). The copy still works; Unity reimports whatever is inconsistent."
        }
        if FileManager.default.fileExists(atPath: library.appendingPathComponent("UnityLockfile").path) {
            return "Unity appears to be open (Library/UnityLockfile). The copy still works; Unity reimports whatever is inconsistent."
        }
        let instance = library.appendingPathComponent("EditorInstance.json")
        guard let data = try? Data(contentsOf: instance),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let pid = (object["processID"] as? NSNumber)?.int32Value ?? (object["pid"] as? NSNumber)?.int32Value ?? 0
        guard pid > 0, kill(pid, 0) == 0 else { return nil }
        return "Unity appears to be open (process \(pid)). The copy still works; Unity reimports whatever is inconsistent."
    }

    /// Atlanan dosya sayısını döndürür (Unity yazarken okunamayan dosyalar).
    @discardableResult
    public func copy(sourcePath: String, workspacePath: String) async throws -> Int {
        let fm = FileManager.default
        let sourceRoot = URL(fileURLWithPath: sourcePath).standardizedFileURL
        let workspaceRoot = URL(fileURLWithPath: workspacePath).standardizedFileURL
        let source = sourceRoot.appendingPathComponent("Library")
        let target = workspaceRoot.appendingPathComponent("Library")
        guard isDirectory(sourceRoot), isDirectory(workspaceRoot), isDirectory(source) else {
            throw WorkspaceFailure("Unity Library source and workspace must be existing directories")
        }
        guard !isSymlink(sourceRoot), !isSymlink(source), !isSymlink(workspaceRoot), !isSymlink(target) else {
            throw WorkspaceFailure("Unity Library and workspace roots cannot be symbolic links")
        }
        let sourcePathCanonical = sourceRoot.resolvingSymlinksInPath().path
        let workspacePathCanonical = workspaceRoot.resolvingSymlinksInPath().path
        guard sourcePathCanonical != workspacePathCanonical,
              !workspacePathCanonical.hasPrefix(sourcePathCanonical + "/"),
              !sourcePathCanonical.hasPrefix(workspacePathCanonical + "/") else {
            throw WorkspaceFailure("Unity Library destination cannot be the source or inside it")
        }
        guard !fm.fileExists(atPath: target.path) else { throw WorkspaceFailure("Destination Library already exists") }
        if let reason = blockedReason(sourcePath: sourcePath) { throw WorkspaceFailure(reason) }

        let staging = workspaceRoot.appendingPathComponent(".lumi-library-staging-\(UUID().uuidString)")
        var ownsStaging = false
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            ownsStaging = true
            let skipped = try await Task.detached(priority: .utility) {
                try Self.copyDirectory(source: source, destination: staging)
            }.value
            guard !fm.fileExists(atPath: target.path) else {
                throw WorkspaceFailure("Destination Library already exists")
            }
            try fm.moveItem(at: staging, to: target)
            return skipped
        } catch {
            if ownsStaging { try? fm.removeItem(at: staging) }
            throw error
        }
    }

    /// Dizin ağacını kopyalar, atlanan dosya sayısını döndürür. Açık bir Unity
    /// tek tük dosyayı kilitli/yarım bırakabilir; bunlar kopyayı iptal etmez
    /// (karar 58) ama sessizce yutulmaz — sayı çağırana uyarı olarak döner.
    /// Symlink hâlâ kesin hatadır: Library dışına çıkan bir bağ kopyalanmaz.
    private static func copyDirectory(source: URL, destination: URL) throws -> Int {
        let fm = FileManager.default
        var skipped = 0
        for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], options: []) {
            try autoreleasepool {
                let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw WorkspaceFailure("Unity Library contains a symbolic link: \(item.lastPathComponent)") }
                if values.isDirectory == true {
                    if item.lastPathComponent == "Temp" || item.lastPathComponent == "Logs" { return }
                    let child = destination.appendingPathComponent(item.lastPathComponent)
                    try fm.createDirectory(at: child, withIntermediateDirectories: false)
                    skipped += try copyDirectory(source: item, destination: child)
                } else if values.isRegularFile == true {
                    do { try fm.copyItem(at: item, to: destination.appendingPathComponent(item.lastPathComponent)) }
                    catch { skipped += 1 }
                }
            }
        }
        return skipped
    }

    private func isDirectory(_ url: URL) -> Bool {
        var directory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}
