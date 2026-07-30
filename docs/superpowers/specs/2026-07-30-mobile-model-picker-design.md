# Tasarım: Çalışan Model Seçici (Spec 3)

Tarih: 2026-07-30
Durum: Onay bekliyor
İzolasyon: `Lumi-worktrees/model-picker` worktree'sinde, `main`'den (Spec 1 + Spec 2 dahil) türetildi.
Roadmap: Spec 1 (chat iyileştirmeleri) ve Spec 2 (izin promptu) tamam. Bu Spec 3.

## Bağlam / problem

Kullanıcı, oturumun hangi modelde çalıştığını mobilde görmek ve değiştirmek istiyor. Bugün mobilde model kavramı yok. Mac tarafında model yalnız **başlatma anı** flag'i (`ClaudeAgentConfig.model` → `--model`). Çalışan bir Claude Code oturumunda model `/model <alias>` slash komutuyla değişir. Gerçek çalışan model, jsonl transcript'inde assistant kayıtlarının `message.model` alanında görünür (Anthropic yanıt formatı); `TranscriptParser` şu an bunu okumuyor.

**Çözüm:** Spec 2 kalıbı — Mac per-session bir model sinyali üretir (snapshot alanı + `model_change` event'i); telefon gösterir; yeni bir `set_model` komutu terminale `/model <alias>` yazar.

## Kararlar (kullanıcı onaylı)

- Değiştirme: **dedicated `set_model` action** → Mac `/model <alias>\r` yazar (chat'e bubble düşmez).
- Picker listesi: **Opus / Sonnet / Haiku / Default** (alias: `opus`/`sonnet`/`haiku`/`default`).
- Güncel model kaynağı: jsonl **`message.model`** parse.
- UI: oturum detayı **toolbar'da Menu** (durum rozeti yanında).
- Mac tarafı **allowlist** doğrulaması (`opus/sonnet/haiku/default`; bilinmeyen → `unknown_model`).

---

## Bileşen 1 — Mac (`LumiRemote`)

### TranscriptParser
- Mac-içi `FeedItem` enum'una `case model(String)` eklenir.
- `parse(line:)`: assistant satırında `message["model"] as? String` varsa, döndürülen `items`'a `.model(m)` eklenir (içerik öğelerinin yanında). Boş/yoksa eklenmez.
- `itemPayload`: `.model` için exhaustive case gerekir → `["itemType": "model", "model": m]` (ama history'de gönderilmez; aşağıya bak).

### RemoteService
- Yeni alan: `private var currentModel: [TerminalID: String] = [:]` (`lastSummary`/`awaitingDecision` kalıbı).
- `handleFeedItem(_:sessionId:)`: `.model(m)` gelince **transcript event olarak telefona gönderilmez**; `currentModel[id]` güncellenir ve **değiştiyse** `model_change` event yayınlanır (`SnapshotBuilder.modelChangeEvent`). Diğer öğeler bugünkü gibi.
- `handleGetHistory`: `items` map'lenirken `.model` öğeleri elenir (history transcript'e model girmez).
- `stopWatcher(for:)`: `currentModel[id] = nil`.
- `sendSnapshot()`: `SnapshotBuilder.snapshot(..., currentModel: currentModel)`.

### SnapshotBuilder
- `snapshot(...)`'a yeni son parametre `currentModel: [TerminalID: String] = [:]`; her entry'ye `if let m = currentModel[meta.id] { entry["model"] = m }`.
- Yeni: `modelChangeEvent(sessionId: String, model: String) -> [String: Any]` → `["kind": "model_change", "sessionId": sessionId, "model": model]`.

### RemoteCommandHandler
- `handle`'a yeni `case "set_model"`:
  ```swift
  case "set_model":
      let model = payload["model"] as? String ?? ""
      guard Self.allowedModels.contains(model) else {
          return ["commandId": commandId, "ok": false, "error": "unknown_model"]
      }
      return result(commandId, run: {
          let id = try self.session(from: payload)
          try self.terminal.write(id: id, text: "/model \(model)\r")
      })
  ```
- `private static let allowedModels: Set<String> = ["opus", "sonnet", "haiku", "default"]`.

## Bileşen 2 — Protokol (`docs/spec/50-remote-protocol.md`, bağlayıcı)

- Yeni komut: `set_model {commandId, sessionId, model}` — model `opus|sonnet|haiku|default`. Hatalar: `session_not_found`, `unknown_model`.
- Yeni event: `model_change {sessionId, model}` — Mac son assistant kaydından çıkardığı güncel modeli bildirir. Relay bakmaz (push yalnız `status_change`).
- Snapshot session şekline opsiyonel `model: string` alanı (yok → bilinmiyor).

## Bileşen 3 — Mobil (`LumiMobileKit`)

### Models
- `SessionSummary.model: String?` (Decodable, `decodeIfPresent`; Spec 2'de eklenen özel `init(from:)`'a bir satır daha).
- `RemoteEvent.modelChange(sessionId: String, model: String)`.

### PhoneProtocol
- `decodeEvent`: `case "model_change"` → `sessionId` + `model` (string; yoksa event düşer/`nil`) → `.modelChange(...)`.
- `CommandAction.setModel(sessionId: String, model: String)`; `commandFrame` → `{action:"set_model", sessionId, model}`.

### AppModel
- Yeni alan: `private var models: [String: String] = [:]` (sessionId → ham model id).
- `apply(snapshot:)`: `models`'ı snapshot session'larının `model` alanından yeniden kurar (liveIds).
- `handle(.event(.modelChange(sessionId, model)))`: `macOnline = true`; `models[sessionId] = model`.
- `unpair()`: `models = [:]`. (statusChange working/idle'da model'e DOKUNULMAZ — model kalıcı bilgidir.)
- `currentModel(for sessionId: String) -> String?` → `models[sessionId]`.
- `setModel(sessionId:model:)` → `dispatch(target: sessionId, action: .setModel(sessionId:model:))`.
- Prettify helper (public, UI kullanır): ham id'yi kısalt — küçük harfe çevir, "opus" içeriyorsa "Opus", "sonnet"→"Sonnet", "haiku"→"Haiku", aksi halde ham id.

## Bileşen 4 — UI (`SessionDetailView`)

Toolbar `.topBarTrailing`'de (mevcut StatusBadge yanında) bir `Menu`:
- Etiket: `model.currentModel(for: sessionId)` varsa prettify'lanmış ad (ör. "Opus"), yoksa "Model".
- İçerik: `Opus`/`Sonnet`/`Haiku`/`Default` butonları → `Task { await model.setModel(sessionId: sessionId, model: <alias>) }`.
- `.disabled(!model.macOnline)`.

## Hata yönetimi / kenar durumlar
- Decode toleransı: bilinmeyen event kind / eksik `model` alanı akışı kırmaz.
- `set_model` başarısızlığı `dispatch` yoluyla `lastCommandError[sessionId]`'e düşer (mevcut kalıp).
- Yeniden bağlanma: snapshot `model` taşıdığından bağlanan telefon güncel modeli görür.
- `/model <alias>` yazımı Claude TUI'ına terminal girdisidir (shell-exec değil); allowlist zaten alias'ı sabit tutar.
- Model, transcript'te ilk assistant yanıtına kadar bilinmeyebilir (yeni oturum) → Menu "Model" gösterir, seçim yine çalışır.

## Test
**LumiRemote:**
- `TranscriptParser.parse` `message.model` olan assistant satırından `.model(m)` üretir; olmayan satırdan üretmez.
- `RemoteService`: `.model` öğesi → `model_change` event (yalnız değişince) + snapshot'ta `model` alanı; `.model` transcript olarak telefona gitmez; history'de elenir; exit temizler.
- `RemoteCommandHandler`: `set_model {model:"opus"}` → `terminal.write` `/model opus\r`; `unknown_model` (bilinmeyen alias); `session_not_found` (bilinmeyen session).

**LumiMobileKit:**
- `decodeEvent` "model_change" → `.modelChange`; snapshot `model` decode (+yoksa nil).
- `commandFrame(.setModel)` → `{action:"set_model", sessionId, model}` round-trip.
- AppModel: modelChange event → `currentModel(for:)`; snapshot'tan doldurma; unpair temizler; statusChange working model'i silmez.
- prettify: "claude-opus-4-8" → "Opus"; "claude-sonnet-4-6" → "Sonnet"; bilinmeyen → ham.

**UI:** derleme (`xcodebuild ... build`) + manuel (model görünür; Opus→Sonnet seçince Mac terminalinde `/model sonnet` çalışır; model_change ile Menu güncellenir).

## Dokunulan dosyalar
- `LumiPackages/Sources/LumiRemote/TranscriptParser.swift`
- `LumiPackages/Sources/LumiRemote/RemoteService.swift`
- `LumiPackages/Sources/LumiRemote/SnapshotBuilder.swift`
- `LumiPackages/Sources/LumiRemote/RemoteCommandHandler.swift`
- `docs/spec/50-remote-protocol.md`
- `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/Models.swift`
- `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PhoneProtocol.swift`
- `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift`
- `LumiMobile/App/SessionDetailView.swift`
- İlgili test dosyaları (LumiRemoteTests, ProtocolTests, AppModelTests)
