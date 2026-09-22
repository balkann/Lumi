import Foundation
import LumiKit

/// Foundation Process + Pipe tabanlı uzun-yaşayan stream-json child (spec §A).
/// PTY değil: saf pipe I/O. stdout satır-sınırlı `AsyncStream`'e; yarım son satır
/// bir sonraki chunk'a taşınır. `Process` ve pipe'lar handle içinde kapsüllenir.
public final class LiveStreamingProcess: StreamingProcessSpawning {
    public init() {}

    public func spawn(executable: String, arguments: [String],
                      currentDirectory: String?, environment: [String: String]) -> any StreamingProcessHandle {
        LiveHandle(executable: executable, arguments: arguments,
                   currentDirectory: currentDirectory, environment: environment)
    }
}

private final class LiveHandle: StreamingProcessHandle, @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let continuation: AsyncStream<String>.Continuation
    let lines: AsyncStream<String>
    private var buffer = Data()
    private let lock = NSLock()

    init(executable: String, arguments: [String], currentDirectory: String?, environment: [String: String]) {
        (lines, continuation) = AsyncStream.makeStream(of: String.self)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd = currentDirectory { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if !environment.isEmpty { process.environment = environment }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.ingest(chunk)
        }
        process.terminationHandler = { [weak self] _ in self?.continuation.finish() }
        do { try process.run() } catch { continuation.finish() }
    }

    private func ingest(_ chunk: Data) {
        var completed: [String] = []
        lock.lock()
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let s = String(data: Data(lineData), encoding: .utf8) {
                completed.append(s)
            }
        }
        lock.unlock()
        // yield kilit DIŞINDA: consumer resume'u kritik bölümü bloklamasın.
        for s in completed { continuation.yield(s) }
    }

    func write(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        stdinPipe.fileHandleForWriting.write(data)
    }

    func terminate() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        continuation.finish()
    }
}
