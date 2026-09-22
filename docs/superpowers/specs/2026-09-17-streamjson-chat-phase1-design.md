# Yol B / Faz 1 — Mac stream-json Chat Çekirdeği — Tasarım

Tarih: 2026-09-17 · Branch: `feat/remote-orca-main` · Durum: kullanıcı onayladı

## Bağlam ve amaç

Telefon chat'inin orca gibi olması (canlı token-token akış + AskUserQuestion sorusundan önceki assistant metninin cevaptan ÖNCE görünmesi + temiz kart) sadece view işi değil, **veri kaynağı** işi. Kanıtlandı: Claude soru beklerken transcript JSONL'i yazmıyor, dolayısıyla transcript-tail aynası soru-öncesi metni gösteremiyor. orca bunu `claude --output-format stream-json` **structured child**'ı canlı okuyarak çözüyor. Lumi'ye bu hattı ekliyoruz.

Bu bütün iş 4 faza bölündü (kullanıcı onayı): **Faz 1** = Mac stream-json veri çekirdeği (bu spec, UI yok); Faz 2 = telefon native chat; Faz 3 = Mac desktop chat view; Faz 4 = olgunlaşma (resume/interrupt/subagent/attachment). Faz 1 en riskli/yeni parçayı headless testlerle kanıtlar.

## Feasibility (doğrulandı, 2026-09-17)

Kurulu `claude` 2.1.196: `-p --input-format stream-json --output-format stream-json --include-partial-messages --verbose --session-id <uuid> [--resume]` destekliyor. Canlı probe'da gözlenen NDJSON event taksonomisi (fixture kaynağı):

- `system` (subtype: `init`, `status`, `hook_started`, `hook_response`, `thinking_tokens`)
- `stream_event` (nested `event.type`: `message_start`, `content_block_start`, `content_block_delta` [text_delta = token-token; input_json_delta = tool input], `content_block_stop`, `message_delta`, `message_stop`)
- `assistant` (tamamlanmış assistant mesajı snapshot'ı — bloklar: text, tool_use)
- `user` (`--replay-user-messages` ile echo; tool_result burada)
- `result` (subtype `success`: usage/cost/duration)
- `rate_limit_event`

Ayrıca **print-mode'da transcript JSONL yazılıyor** (`--session-id` yolu) → kalıcı geçmiş mevcut `TranscriptChatSource` ile hazır; canlı turu stream-json sağlar.

Kritik bulgu: `assistant` snapshot'ının blok şekli mevcut `ClaudeTranscriptChatDecoder`'ın çözdüğüyle **aynı** → tamamlanmış mesaj üretimi paylaşılır (DRY). Yeni olan tek şey **canlı streaming katmanı** (`content_block_delta`) + **streaming süreç yönetimi**.

## Mimari değişikliği (bağlayıcı kayıtlar bu fazda güncellenir)

Bugün her Lumi oturumu bir PTY terminal (view-attached SwiftTerm). Faz 1 ikinci bir oturum türü getirir: **chat oturumu = PTY'siz stream-json child**. `docs/design/00-architecture.md`'ye "chat lane (stream-json)" bölümü ve `SessionKind` eklenir; chat oturumlarının PTY→UI backpressure / replay güvenliği gereksinimlerinden (Ek A) **muaf** olduğu belirtilir (pipe I/O, TUI yok). `docs/decisions.md`'ye yeni karar yazılır. Bu değişiklik implementasyonun bir parçasıdır (spec'i onaylayan kullanıcı bu doc değişikliğini de onaylamış olur).

## Bileşenler

Her biri tek sorumluluk, enjekte edilebilir, fake'lenebilir.

### A. `StreamingProcess` soyutlaması (LumiKit protokol + LumiServices canlı impl)
Uzun-yaşayan süreç: satır-sınırlı stdout `AsyncStream<String>`, `write(Data)` ile stdin, `terminate()`, exit sinyali. Mevcut `ProcessRunning` **tek-atışlık** (run→ProcessOutput, stdin upfront Data) olduğundan yetersiz → yeni soyutlama. **PTY değil** — stream-json saf pipe I/O; PTY TUI kontrol dizileri karıştırır. Canlı impl Foundation `Process` + `Pipe`; yarım satır tamponlama (son newline'a kadar; kalanı taşınır — mevcut transcript-tail kalıbı). Fake (scripted satırlar + yazılan stdin yakalama) → `LumiTestSupport`. Env, mevcut `TerminalEnvironment` hijyeniyle temizlenir (`CLAUDECODE`/`CLAUDE_CODE_*`/`CLAUDE_EFFORT` sıfırlanır, `CLAUDE_CONFIG_DIR` korunur).

### B. `StreamJsonEvent` decode (LumiKit, saf)
NDJSON satırı → tip'li enum. En az şu case'ler (probe taksonomisi): `.systemInit(sessionID, model, cwd)`, `.streamTextDelta(String)`, `.assistantSnapshot([ChatBlock])`, `.userEcho([ChatBlock])`, `.turnResult(usage)`, `.rateLimit`, `.ignored`. Bilinmeyen/parse edilemeyen satır `.ignored` (akış ölmez) + diag log. Tamamlanmış blok çözümü `ClaudeTranscriptChatDecoder`'ın blok mantığıyla paylaşılır (ortak bir `ClaudeContentBlockDecoding` yardımcısına çıkarılır; transcript decoder da bunu kullanır → tek kaynak).

### C. `ChatJournal` + reducer (LumiKit, saf)
Event akışını, mevcut wire tipleriyle uyumlu bir duruma katlar (Faz 2 wire'ı yeniden kullansın diye):
- `messages: [ChatMessage]` — tamamlanmış mesajlar (`assistant` snapshot + `user` echo'dan; `ChatMessage`/`ChatBlock` mevcut LumiWire tipleri).
- `streamingText: String?` — canlı, in-flight assistant metni (`content_block_delta` text_delta'larından birikir); assistant snapshot landing'de temizlenir (orca streaming-gate mantığı: snapshot metni streaming'i geçince overlay düşer).
- `turnActive: Bool`, `lastUsage`.
`reduce(_ event:) -> [Change]` (değişen alanlar). Testler: gerçek NDJSON fixture dizileri → beklenen journal durumu. AskUserQuestion, `assistant` bloklarında bir `tool_use` (name=AskUserQuestion) olarak görünür → journal onu `ChatBlock.toolCall` olarak taşır (soru KARTI + cevap Faz 2). Faz 1'de journal soruyu bir mesaj bloğu olarak doğru temsil etmekle yükümlü; interaktif cevap değil.

### D. `StreamJsonAgentSession` (LumiServices)
`StreamingProcess`'i `BinaryLocating`'le bulunan claude + yukarıdaki bayraklarla spawn eder; `send(_ text: String)` kullanıcı mesajını NDJSON'a (`{"type":"user","message":{"role":"user","content":[{"type":"text","text":...}]}}`) çevirip stdin'e yazar; stdout satırlarını `StreamJsonEvent.decode` → `ChatJournal.reduce` zincirinden geçirir; journal snapshot/patch `AsyncStream`'ini dışa verir. Yaşam döngüsü: spawn → çalışıyor → child exit/terminate → journal `turnActive=false` + session `.ended`. Fake `StreamingProcess` ile test: scripted NDJSON beslenir, journal snapshot doğrulanır, `send`'in doğru NDJSON'u yazdığı doğrulanır.

### E. `SessionKind` (`terminal | chat`) + chat oturum modeli
Chat oturumları terminal modelini (TerminalMeta/PTY) **kirletmeden** ayrı tutulur: `SessionKind = terminal | chat` ve `ChatSessionMeta` (id = claude session-id, repoPath, createdAt). Faz 1'de tek-oturum actor'ı `StreamJsonAgentSession` (§D) bu modeli taşır; **çok-oturum yöneticisi (create/list/close) Faz 2'ye ertelenir** (UI/wire oturumları orada oluşturur — Faz 1'de tüketici yok, erken scaffolding yapılmaz). `~/.lumi` formatlarına dokunulmaz; geçmiş claude transcript'inde kalıcı.

## Veri akışı

```
kullanıcı metni ─send()→ NDJSON ─stdin→ claude(stream-json child)
                                              │ stdout NDJSON
                              StreamingProcess.lines
                                              │
                        StreamJsonEvent.decode (satır → event)
                                              │
                          ChatJournal.reduce (event → durum)
                                              │
              journal snapshot/patch AsyncStream  → (Faz 2: telefon frame'leri)
```

## Hata durumları
- Child çöker/exit → journal `turnActive=false`, session `.ended`; kısmi stdout yarım satırı düşürülür.
- Parse edilemeyen NDJSON satırı → `.ignored` + diag; akış devam eder.
- claude bulunamaz (`BinaryLocating` nil) → session spawn hatası (Faz 1: hata döndürülür, UI yok).
- Env kirliliği → `TerminalEnvironment` hijyeni (mevcut çözüm yeniden kullanılır).

## Test stratejisi (hepsi headless)
- `StreamJsonEvent` decode: gerçek probe NDJSON fixture'ları (system/init, stream_event delta, assistant snapshot, result) → beklenen event'ler; bilinmeyen satır `.ignored`.
- `ChatJournal` reducer: scripted event dizisi → `messages` + `streamingText` + `turnActive`; streaming overlay'in snapshot landing'de düşmesi; tool_use bloğunun mesajda taşınması.
- `StreamingProcess` canlı impl: küçük bir echo/cat süreciyle satır-sınırlama + yarım-satır tamponlama testi (opsiyonel entegrasyon).
- `StreamJsonAgentSession`: Fake `StreamingProcess` → scripted NDJSON → journal snapshot doğru; `send()` doğru NDJSON yazıyor; child exit → `.ended`.
- `ClaudeContentBlockDecoding` ortak yardımcısı: transcript decoder regresyon testleri yeşil kalır (paylaşım kırmadı).

## Kapsam dışı (sonraki fazlar)
- Telefon/Mac UI (Faz 2/3).
- Geçmiş transcript'ten seed + resume/restore (Faz 2/4).
- Çok-oturum yöneticisi (create/list/close chat oturumu) — Faz 2.
- Soru cevabı/izin (permission) protokolü, interrupt, subagent, model seçimi, attachment (Faz 2/4).
- Relay değişmez (bu fazda zaten wire yok).
