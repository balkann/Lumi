# Tasarım: Tool-use İzin Promptu Görünürlüğü (Spec 2)

Tarih: 2026-07-30
Durum: Onay bekliyor
Roadmap: Spec 1 (mobil chat iyileştirmeleri) tamam ve merge edildi. Spec 3 = çalışan model seçici (sonra).

## Bağlam / problem

Claude Code bir tool için izin isteyince (ör. "Bash şu komutu çalıştırsın mı? 1.Evet 2.Evet+sorma 3.Hayır"), bu prompt terminal-içi interaktif UI'dır; jsonl transcript'e yazılmaz. Bu yüzden telefonun distile feed'i onu içermez ve kullanıcı "izin istendiğini göremiyorum, süreç tıkanıyor" diyor.

Mac aslında izin isteğini **zaten tespit ediyor**: `OSCStreamParser` ("needs your permission") → `DecisionTracker` → `TerminalEvent.awaitingDecisionChanged(id, Bool)`. Ancak `RemoteService.handleTerminalEvent` bu event'i düşürüyor (yalnız `.spawned/.exited/.statusChanged` işleniyor). Telefon yalnız kaba "waiting" rozetini alıyor — ve o rozet OSC **başlık** değişimine bağlı (`StatusStateMachine.onTitleChange`), izin sinyaline değil. Yani rozet güvenilmez; kart bazen hiç çıkmıyor.

**Çözüm (yaklaşım C-plus, kullanıcı onaylı):** Mevcut `awaitingDecision` sinyalini telefona ilet; telefonda ayrı bir **izin kartı** göster. İçeriği için yeni ANSI parse yok — mevcut son `tool_use` özeti kullanılır.

## Kararlar (kullanıcı onaylı)

- İzin kartı, `awaitingDecision` sinyaliyle sürülür — **rozetten bağımsız** (rozet güvenilmez olduğu için).
- Buton etiketleri: **`1 · Evet`**, **`2 · Evet, bir daha sorma`**, **`3 · Hayır`** + `Esc`. (pressKey 1/2/3/esc.)
- Komut/bağlam kaynağı: feed'deki **son `tool_use` özeti** (yeni parse yok).

---

## Bileşen 1 — Mac (`LumiRemote`)

### RemoteService
- Yeni alan: `private var awaitingDecision: [TerminalID: Bool] = [:]` (session başına son karar durumu; `lastSummary` kalıbı).
- `handleTerminalEvent`'e yeni case:
  ```swift
  case .awaitingDecisionChanged(let id, let awaiting):
      awaitingDecision[id] = awaiting
      guard let meta = terminal.terminals.first(where: { $0.id == id }) else { return }
      await connection.send(type: "event",
          payload: SnapshotBuilder.awaitingDecisionEvent(sessionId: meta.id.description, awaiting: awaiting))
  ```
- `stopWatcher`/exit temizliğinde `awaitingDecision[id] = nil` (session bitince durum kalmasın).
- `sendSnapshot` yolunda snapshot'a bu durumu geçir (aşağıya bak).

### SnapshotBuilder
- Yeni saf yardımcı:
  ```swift
  static func awaitingDecisionEvent(sessionId: String, awaiting: Bool) -> [String: Any] {
      ["kind": "awaiting_decision", "sessionId": sessionId, "awaiting": awaiting]
  }
  ```
- `snapshot(...)` her session entry'sine `awaitingDecision` alanı ekler (yalnız `true` iken; `false`/eksik telefonda `false` olarak yorumlanır). Bunun için `snapshot(...)`'a `awaitingDecision: [TerminalID: Bool]` parametresi eklenir ve `RemoteService` çağrısı bunu geçirir.

## Bileşen 2 — Protokol (`docs/spec/50-remote-protocol.md`, bağlayıcı)

- Yeni event kind eklenir: `awaiting_decision {sessionId, awaiting: bool}` — Mac izin bekleme durumu değişince yayınlanır; relay bakmaz (push kuralı yalnız `status_change`).
- Snapshot session şekline opsiyonel `awaitingDecision: bool` alanı belgelenir (yok → `false`).

## Bileşen 3 — Mobil (`LumiMobileKit`)

### Models
- `RemoteEvent`: yeni case `.awaitingDecision(sessionId: String, awaiting: Bool)`.
- `SessionSummary`: `public let awaitingDecision: Bool` (Decodable; snapshot'ta yoksa `false`). `decodeIfPresent` ile toleranslı.
- `QuestionCard`'a ayrım alanı (düşük-churn; enum yerine bayrak — mevcut Spec 1 testleri ve view kırılmasın):
  ```swift
  public struct QuestionCard: Sendable, Equatable {
      public let questions: [Question]?
      public let context: String?
      public let isPermission: Bool   // YENİ

      public init(questions: [Question]?, context: String?, isPermission: Bool = false) {
          self.questions = questions
          self.context = context
          self.isPermission = isPermission
      }
  }
  ```
  `isPermission` varsayılanı `false` olduğundan mevcut `QuestionCard(questions:context:)` çağrıları ve `.questions`/`.context` erişimleri aynen derlenir/geçer.
  - Gerçek soru: `QuestionCard(questions: qs, context: nil)` (isPermission false) — değişmedi.
  - İzin: `QuestionCard(questions: nil, context: command, isPermission: true)`.
  - Girdi bekliyor: `QuestionCard(questions: nil, context: ctx)` (isPermission false) — değişmedi.

### PhoneProtocol
- `decodeEvent`: `case "awaiting_decision"` → `sessionId` + `awaiting` (bool, default false) → `.awaitingDecision(...)`.
- Snapshot decode zaten `SessionSummary`'yi Decodable ile çözüyor → `awaitingDecision` otomatik (default false).

### AppModel
- Yeni alan: `private var decisionPending: [String: Bool] = [:]`.
- `apply(snapshot:)`: `decisionPending`'i snapshot session'larından doldur (`awaitingDecision == true` olanlar); liveIds filtresi mevcut kalıpla.
- `handle(.event(.awaitingDecision(sessionId, awaiting)))`: `decisionPending[sessionId] = awaiting` (false → sil), `macOnline = true`.
- `handle(.event(.statusChange...))`: status badge `.working/.idle` olunca `decisionPending[sessionId] = nil` (mevcut `activeQuestions` temizliğinin yanında — defensive).
- `dispatch` (cevap gönderilince, target boş değilse): mevcut `activeQuestions[target] = nil` yanında `decisionPending[target] = nil` (izne cevap verildi → kart kalksın).
- `unpair()`: `decisionPending = [:]`.
- `questionCard(for:)` yeni öncelik:
  1. `activeQuestions[sessionId]` varsa → `QuestionCard(questions: qs, context: nil)` (değişmedi).
  2. `decisionPending[sessionId] == true` → `QuestionCard(questions: nil, context: <son tool_use özeti>, isPermission: true)` — `context` = feed'deki son `tool_use` özeti (`"tool: summary"`; yoksa nil). **Rozetten bağımsız.**
  3. `session(sessionId)?.status.badge == .waiting` → `QuestionCard(questions: nil, context: <son tool_use özeti>)` (mevcut jenerik davranış).
  4. nil.

## Bileşen 4 — UI (`SessionDetailView` / `QuestionCardView`)

`QuestionCardView` dallanması (öncelik: questions → isPermission → jenerik):
- `card.questions` non-nil → bugünkü soru kartı (header + question + 1/2/3 seçenek etiketleri + Enter/Esc).
- `card.isPermission` → turuncu başlık "İzin isteği"; `card.context` varsa monospace/belirgin (ör. `Bash: swift test`); butonlar `1 · Evet`, `2 · Evet, bir daha sorma`, `3 · Hayır` (pressKey "1"/"2"/"3") + `Esc` (pressKey "esc"). `disabled = !macOnline`.
- aksi halde → bugünkü jenerik "Oturum girdi bekliyor" + context + 1/2/3 + Enter/Esc.

## Hata yönetimi / kenar durumlar
- Decode toleransı korunur: bilinmeyen event kind / eksik `awaiting` alanı akışı kırmaz (`awaiting` eksikse false).
- Yeniden bağlanma: welcome snapshot `awaitingDecision` taşıdığından, ortada izin varken bağlanan telefon kartı görür.
- `awaitingDecision` canlı durumdur; `get_history` taşımaz (transcript'te yok) — sorun değil, event/snapshot taşır.
- İzin cevaplanınca: Mac `awaitingDecisionChanged(false)` → event → temizlenir; ayrıca telefon cevabı gönderince `dispatch` optimistik temizler.

## Test
**LumiRemote:**
- `awaitingDecisionChanged(true/false)` → doğru `awaiting_decision` event payload'ı; bilinmeyen id → no-op.
- `snapshot(...)` `awaitingDecision:true` olan session'a alan koyar, false/eksik koymaz.
- session exit → `awaitingDecision` temizlenir (sonraki snapshot'ta yok).

**LumiMobileKit (Protocol + AppModel):**
- `decodeEvent` "awaiting_decision" → `.awaitingDecision`; `awaiting` eksik → false.
- `SessionSummary` decode: `awaitingDecision` alanı var/yok (default false).
- AppModel: awaiting_decision event → `decisionPending` set/clear; snapshot'tan doldurma; status→working temizler; cevap gönderince (`pressKey`) temizler.
- `questionCard` önceliği: decisionPending true iken rozet waiting değilken bile `isPermission:true` kartı; gerçek soru varsa questions-kartı öncelikli; ikisi de yokken waiting → jenerik (isPermission false).
- izin kartının context'i = son tool_use özeti; tool yoksa nil.

**UI:** derleme (`xcodebuild ... build`) + manuel (gerçek Lumi'de izin promptu → telefonda izin kartı; "Evet"/"Hayır" ile cevap → Mac ilerler).

## Dokunulan dosyalar
- `LumiPackages/Sources/LumiRemote/RemoteService.swift`
- `LumiPackages/Sources/LumiRemote/SnapshotBuilder.swift`
- `docs/spec/50-remote-protocol.md`
- `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/Models.swift`
- `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PhoneProtocol.swift`
- `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift`
- `LumiMobile/App/SessionDetailView.swift`
- İlgili test dosyaları (LumiRemoteTests, ProtocolTests, AppModelTests)
