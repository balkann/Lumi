import Foundation
import LumiKit

/// `~/.claude/deepseek.env` dosyasını okur/yazar/siler (karar 54).
///
/// Sınırlar:
/// - Anahtar sınırda doğrulanır (`DeepSeekEnvironment.isValidAPIKey`); geçersiz
///   değer diske ULAŞMAZ.
/// - Yazım atomiktir ve dosya izni 0600'e çekilir (dosya bir sır taşır).
/// - `~/.claude` yoksa YARATILIR: env dosyası Lumi'nin ürettiği bir artefakttır
///   ve kurulum kullanıcının açık eylemidir (karar 45'in "başkasının dizinini
///   yaratma" kuralı hook kurulumuna özgüdür, burada kurulum başarısız olmaz).
public actor DeepSeekEnvironmentService: DeepSeekEnvironmentServicing {
    private let envFile: URL
    private var fileManager: FileManager { .default }

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        envFile = homeDirectory
            .appendingPathComponent(DeepSeekEnvironment.directoryName)
            .appendingPathComponent(DeepSeekEnvironment.fileName)
    }

    public func read() async -> DeepSeekSetup {
        guard let contents = try? String(contentsOf: envFile, encoding: .utf8) else {
            return DeepSeekSetup(envFilePath: envFile.path, apiKey: nil)
        }
        return DeepSeekSetup(
            envFilePath: envFile.path,
            apiKey: DeepSeekEnvironment.apiKey(inFileContents: contents)
        )
    }

    public func install(apiKey: String) async throws -> DeepSeekSetup {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DeepSeekEnvironment.isValidAPIKey(trimmed) else {
            throw LumiError.configIOFailed(
                file: envFile.path,
                detail: "DeepSeek API key is empty or contains characters that are unsafe in a shell file"
            )
        }
        do {
            try fileManager.createDirectory(
                at: envFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = Data(DeepSeekEnvironment.fileContents(apiKey: trimmed).utf8)
            try data.write(to: envFile, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envFile.path)
        } catch {
            throw LumiError.configIOFailed(file: envFile.path, detail: error.localizedDescription)
        }
        return DeepSeekSetup(envFilePath: envFile.path, apiKey: trimmed)
    }

    public func remove() async throws -> DeepSeekSetup {
        if fileManager.fileExists(atPath: envFile.path) {
            do {
                try fileManager.removeItem(at: envFile)
            } catch {
                throw LumiError.configIOFailed(file: envFile.path, detail: error.localizedDescription)
            }
        }
        return DeepSeekSetup(envFilePath: envFile.path, apiKey: nil)
    }
}
