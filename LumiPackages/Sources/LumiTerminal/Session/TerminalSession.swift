import AppKit
import Foundation
import LumiKit
import SwiftTerm

@MainActor
protocol TerminalSessionDelegate: AnyObject {
    func session(_ session: TerminalSession, didChangeStatus status: TerminalStatus)
    func session(_ session: TerminalSession, didChangeAwaitingDecision awaiting: Bool)
    func session(_ session: TerminalSession, didDetectPrompt prompt: DetectedPrompt?)
    /// Parse edilemeyen bekleyen prompt için ham ekran özeti (spec 4 §K3, bare kart bağlamı).
    func session(_ session: TerminalSession, didUpdateScreenTail tail: [String])
    func session(_ session: TerminalSession, didChangeTitle title: String)
    func session(_ session: TerminalSession, didExitWithCode code: Int32)
    func sessionDidBell(_ session: TerminalSession)
}

/// Bir PTY oturumu + kalıcı SwiftTerm emülatörü (design/01 §1 — Seçenek A).
///
/// View PTY ömrü boyunca yaşar ve asla yok edilmez; ekran durumu yalnız burada,
/// emülatördedir. Replay/snapshot makinesi yoktur. PTY I/O io queue'da,
/// emülatör feed'i MainActor'da akar; ack senkron feed dönüşünde verilir.
@MainActor
final class TerminalSession {
    static let initialCols: UInt16 = 120
    static let initialRows: UInt16 = 30
    static let scrollbackLines = 5000
    static let resizeDebounceInterval: TimeInterval = 0.15

    let id: TerminalID
    private(set) var meta: TerminalMeta
    let terminalView: TerminalView
    weak var delegate: TerminalSessionDelegate?

    private let pty: PTYProcess
    private let ioQueue: DispatchQueue
    private let pipeline: TerminalPipeline
    private let outputBroadcaster = EventBroadcaster<String>()
    private var isTerminated = false
    private var pendingResize: DispatchWorkItem?
    private var lastPrompt: DetectedPrompt?
    private var lastScreenTail: [String] = []
    private var launchGate = LaunchCommandGate()
    /// Launch komutu bekletilirken yapılan quiescence tarama sayısı (teşhis logu).
    private var launchScanCount = 0

    init(repoPath: String, name: String, task: String?, font: NSFont) throws {
        let id = TerminalID()
        self.id = id
        self.meta = TerminalMeta(
            id: id,
            name: name,
            repoPath: repoPath,
            createdAt: Date(),
            task: task
        )

        let queue = DispatchQueue(label: "lumi.terminal.\(id.raw.uuidString)", qos: .utility)
        self.ioQueue = queue
        self.pipeline = TerminalPipeline(queue: queue)

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        if environment["LANG"] == nil {
            environment["LANG"] = "en_US.UTF-8"
        }

        self.pty = try PTYProcess(
            executable: ShellResolver.defaultShell(),
            args: ["-l"],
            cwd: repoPath,
            env: environment,
            initialCols: Self.initialCols,
            initialRows: Self.initialRows,
            queue: queue
        )

        let view = DropAwareTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 480),
            font: font
        )
        self.terminalView = view
        terminalView.getTerminal().options.scrollback = Self.scrollbackLines
        terminalView.terminalDelegate = self
        view.onFileDrop = { [weak self] paths in
            // Quote'lanmış path, newline'sız yazılır (Electron paritesi + karar 11)
            self?.write(ShellQuoting.joinedPaths(paths))
        }

        wirePipeline()

        pty.onExit = { [weak self, pipeline] code in
            // io queue: önce timer iptal + kalan buffer flush (spec/10 §9),
            // sonra main'e exit bildirimi — main FIFO teslim sırasını korur
            pipeline.prepareForExit()
            hopToMain { self?.handleExit(code: code) }
        }
        pty.startReading { [pipeline] data in
            pipeline.processOutput(data)
        }
    }

    // MARK: - Pipeline kablolaması (io → main)

    private func wirePipeline() {
        pipeline.onFlushBatch = { [weak self] data in
            hopToMain { self?.deliver(data) }
        }
        pipeline.onStatusChange = { [weak self] status in
            hopToMain { self?.applyStatus(status) }
        }
        pipeline.onAwaitingDecisionChange = { [weak self] awaiting in
            hopToMain { self?.applyAwaitingDecision(awaiting) }
        }
        pipeline.onDisplayTitle = { [weak self] title in
            hopToMain { self?.applyTitle(title) }
        }
        pipeline.onPromptScanDue = { [weak self] in
            hopToMain { self?.runPromptScan() }
        }
        // wait_for fan-out (design/01 §3): io queue'dan doğrudan yayın —
        // tüketici yavaşlığı terminali durduramaz
        pipeline.onOutputText = { [outputBroadcaster] text in
            outputBroadcaster.send(text)
        }
    }

    func outputStream() -> AsyncStream<String> {
        outputBroadcaster.stream()
    }

    /// Ack noktası: SwiftTerm feed'i senkron parse eder; dönüş = tüketildi
    /// (spec/00 §4.1-2). Ölü oturuma teslim sessizce atlanır (native safeSend) —
    /// PTY suspend'de kalır, veri kaybolmaz.
    private func deliver(_ batch: Data) {
        guard !isTerminated else { return }
        terminalView.feed(byteArray: ArraySlice([UInt8](batch)))
        if pipeline.flow.noteConsumed(batch.count) {
            pty.resumeReading()
        }
    }

    private func applyStatus(_ status: TerminalStatus) {
        guard !isTerminated else { return }
        meta.status = status
        delegate?.session(self, didChangeStatus: status)
    }

    private func applyAwaitingDecision(_ awaiting: Bool) {
        guard !isTerminated else { return }
        delegate?.session(self, didChangeAwaitingDecision: awaiting)
    }

    /// Spawn'daki başlangıç komutunu shell hazır olana dek bekletir; enjeksiyon
    /// quiescence'ta `runPromptScan` içinde yapılır (LaunchCommandGate).
    func enqueueLaunchCommand(_ command: String) {
        launchGate.arm(command)
        DiagLog.shared.log("terminal", "launch armed \(id.raw.uuidString.prefix(8))")
    }

    /// Çıktı sessizliğinde (io queue debounce) main'de tetiklenir: alt satırları
    /// tarar, son sonuçtan farklıysa delegate'e bildirir. Salt-okuma (spec 4 §K4);
    /// tek istisna bekleyen başlangıç komutunun shell hazırken enjeksiyonu.
    private func runPromptScan() {
        guard !isTerminated else { return }
        // Launch-gate grid'in TAMAMINI görür: taze shell prompt'u üstte render olur,
        // sabit alt-16 penceresi onu kaçırıp gate'i sonsuz hold'a sokuyordu
        // (sandout_word-puzzle "chat başlamıyor" bugı). Bkz. LaunchGateScan.
        if let command = launchGate.commandToInject(
            bottomLines: LaunchGateScan.lines(fromGrid: captureAllLines())) {
            DiagLog.shared.log("terminal", "launch inject \(id.raw.uuidString.prefix(8)) scan#\(launchScanCount)")
            write(command + "\r")
        } else if launchGate.isPending {
            launchScanCount += 1
            if launchScanCount <= 8 {   // salt-teşhis: neden bekliyoruz (son dolu satır)
                let last = captureAllLines().last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
                DiagLog.shared.log(
                    "terminal",
                    "launch hold scan#\(launchScanCount) \(id.raw.uuidString.prefix(8)) son=\(last)")
            }
        }
        let lines = captureBottomLines()
        let prompt = TerminalPromptScanner.scan(lines: lines)
        if prompt != lastPrompt {
            lastPrompt = prompt
            delegate?.session(self, didDetectPrompt: prompt)
        }
        // Yapısal prompt yoksa ham ekran özetini yolla (telefonda bare kart bağlamı);
        // yapısal prompt varsa özeti temizle (activePrompt zaten tam bilgiyi taşır).
        let tail = prompt == nil ? TerminalPromptScanner.screenTail(lines: lines) : []
        if tail != lastScreenTail {
            lastScreenTail = tail
            delegate?.session(self, didUpdateScreenTail: tail)
        }
    }

    /// Emülatörün TÜM görünür satırlarını düz metin olarak okur (MainActor).
    /// Launch-gate bunu kullanır: taze shell prompt'u grid'in üstünde render olur,
    /// sabit alt pencere onu kaçırırdı (bkz. LaunchGateScan, runPromptScan).
    private func captureAllLines() -> [String] {
        let terminal = terminalView.getTerminal()
        let rows = terminal.rows
        var out: [String] = []
        for row in 0..<rows {
            out.append(terminal.getLine(row: row)?.translateToString(trimRight: true) ?? "")
        }
        return out
    }

    /// Emülatörün görünür alt `n` satırını düz metin olarak okur (MainActor).
    private func captureBottomLines(_ n: Int = 16) -> [String] {
        let terminal = terminalView.getTerminal()
        let rows = terminal.rows
        let start = max(0, rows - n)
        var out: [String] = []
        for row in start..<rows {
            out.append(terminal.getLine(row: row)?.translateToString(trimRight: true) ?? "")
        }
        return out
    }

    private func applyTitle(_ title: String) {
        guard !isTerminated else { return }
        meta.oscTitle = title
        delegate?.session(self, didChangeTitle: title)
    }

    private func handleExit(code: Int32) {
        guard !isTerminated else { return }
        isTerminated = true
        pendingResize?.cancel()
        delegate?.session(self, didExitWithCode: code)
    }

    // MARK: - Komutlar

    func write(_ text: String) {
        write(Data(text.utf8))
    }

    /// Tüm PTY-bound yazımların tek hunisi (design/01 §4): klavye, SwiftTerm
    /// oto-yanıtları, ActionEngine, persona — hepsi filtre + serial io queue'dan geçer.
    func write(_ data: Data) {
        guard !isTerminated else { return }
        ioQueue.async { [pipeline, pty] in
            let filtered = pipeline.processInput(data)
            guard !filtered.isEmpty else { return }
            pty.write(filtered)
        }
    }

    func requestResize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0, !isTerminated else { return }
        pendingResize?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isTerminated else { return }
            self.ioQueue.async { [pty = self.pty] in
                pty.resize(cols: UInt16(cols), rows: UInt16(rows))
            }
        }
        pendingResize = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resizeDebounceInterval, execute: work)
    }

    func setTabFocused(_ focused: Bool) {
        ioQueue.async { [pipeline] in
            pipeline.setTabFocused(focused)
        }
    }

    func setWindowFocused(_ focused: Bool) {
        ioQueue.async { [pipeline] in
            pipeline.setWindowFocused(focused)
        }
    }

    func setHidden(_ hidden: Bool) {
        ioQueue.async { [pipeline] in
            pipeline.setHidden(hidden)
        }
    }

    /// Gizli→görünür geçişi (grid↔maximize round-trip, fullscreen) sonrası TUI'yi
    /// tüm ekranı yeniden çizmeye zorlar. Boyut değişmediğinde hiçbir resize
    /// tetiklenmediğinden emülatör reflow'u ekranda görünmüyor, kart boş kalıyordu
    /// (needsDisplay tek başına yetmiyor — TUI ancak SIGWINCH ile repaint eder).
    /// Asıl onarım: `updateFullScreen` tüm hücreleri dirty işaretler, böylece
    /// reattach sonrası (dirty hücre kalmadığından `needsDisplay` tek başına boş
    /// çizerdi) emülatör buffer'ındaki son kare hem TUI hem düz bash için anında
    /// görünür. Ek olarak SIGWINCH poke'u TUI'nin (Claude Code) iç durumunu da
    /// tazeler. requestRepaint MainActor'da çağrılır.
    func requestRepaint() {
        guard !isTerminated else { return }
        redrawFromBuffer()
        pty.pokeRepaint()
    }

    /// Buffer'dan tam yeniden çizim, SIGWINCH poke'u OLMADAN. Frame-oturma
    /// yolunda (tab değişimi sonrası reassert, pencere resize) kullanılır —
    /// boyut değiştiyse SwiftTerm sizeChanged → PTY resize zinciri SIGWINCH'i
    /// zaten üretir; her layout frame'inde ek poke TUI'yi spam'lerdi.
    func redrawFromBuffer() {
        guard !isTerminated else { return }
        terminalView.getTerminal().updateFullScreen()
        terminalView.setNeedsDisplay(terminalView.bounds)
    }

    /// Stem-darkening toggle'ı (Settings → Font Smoothing). CG draw path'i
    /// değeri her çizimde okur; tam dirty + redraw anında etki ettirir.
    func setFontSmoothing(_ enabled: Bool) {
        guard terminalView.fontSmoothing != enabled else { return }
        terminalView.fontSmoothing = enabled
        redrawFromBuffer()
    }

    /// Renk teması canlı uygular (Settings → Theme). `installColors` 256-paleti
    /// kendisi redraw'lar; ama native bg/fg/selection setter'ları redraw
    /// tetiklemediğinden ardından buffer'dan tam çizim gerekir.
    func applyTheme(_ theme: TerminalTheme) {
        guard !isTerminated else { return }
        theme.apply(to: terminalView)
        redrawFromBuffer()
    }

    /// Caret şekli + blink canlı uygular (Settings → Cursor). SwiftTerm caret'i
    /// otomatik günceller; ek redraw gerekmez.
    func setCursorStyle(_ style: CursorStyle) {
        guard !isTerminated else { return }
        terminalView.getTerminal().setCursorStyle(style)
    }

    /// Font (aile + boyut) canlı uygular. SwiftTerm setter zinciri hücre
    /// boyutlarını yeniden hesaplar, resize'lar (PTY'ye SIGWINCH) ve needsDisplay
    /// işaretler — ek iş gerekmez.
    func setFont(_ font: NSFont) {
        guard !isTerminated else { return }
        terminalView.font = font
    }

    func terminate() {
        pty.terminate()
    }
}

// MARK: - SwiftTerm delegate köprüsü

/// Delegate çağrıları AppKit'ten (main) gelir; protokol isolasyonsuz olduğundan
/// @preconcurrency conformance runtime'da MainActor'ı doğrular.
extension TerminalSession: @preconcurrency TerminalViewDelegate {
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        requestResize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        // Bilinçli no-op: title semantiğini Lumi'nin kendi OSC parser'ı sürer (design/01 §6)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        // Klavye + emülatör oto-yanıtları (mode 1004 focus event'leri dahil) —
        // hepsi filtreli yazma hunisinden geçer
        write(Data(data))
    }

    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        // http/https whitelist paritesi (spec/00 §5)
        guard let url = URL(string: link),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }
        NSWorkspace.shared.open(url)
    }

    func bell(source: TerminalView) {
        guard !isTerminated else { return }
        delegate?.sessionDidBell(self)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        // OSC 52: Electron sürümünde yoktu; bilinçli no-op (parite)
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
