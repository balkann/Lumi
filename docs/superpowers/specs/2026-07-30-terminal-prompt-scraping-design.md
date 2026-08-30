# Tasarım: Terminal-ekran Prompt Dedektörü (Spec 4)

Tarih: 2026-07-30
Durum: Onay bekliyor
Roadmap: Spec 2 (tool-use izin promptu, `awaitingDecision` sinyali) merge edildi ama **kısıtlı**: kartın içeriği yalnız "son `tool_use` özeti"ydi; gerçek seçenek metinleri (1.Evet / 2.Evet-sorma / 3.Hayır, plan-onay şıkları, AskUserQuestion menüsü) telefonda görünmüyordu. Bu spec o eksiği kapatır ve **ekranı gerçek seçeneklerin tek kaynağı** yapar.

## Bağlam / problem

Claude Code'un interaktif seçim promptları (tool/skill izin diyaloğu, plan-onay, AskUserQuestion menüsü) **terminal-içi UI**dır. İki gözlem:

1. **İzin/onay diyaloglarının seçenek metni JSONL transcript'e yazılmaz** (doğrulandı: `~/.claude/projects/.../<session>.jsonl` içinde "Use skill", "Do you want to proceed", "don't ask again" = 0 eşleşme). Transcript yalnız `tool_use` isteğini taşır (ör. `Skill{skill:"artifact-design"}`), seçim UI'sını değil.
2. Bu yüzden telefon ya jenerik "Oturum girdi bekliyor" kartına (çıplak 1/2/3 butonu, ne onayladığın belirsiz) ya da Spec 2'nin izin kartına (yalnız son tool özeti) düşüyor. Kullanıcı: "telefonda hatalı görünüyor, ne yapacağımı bilemiyorum."

`AskUserQuestion` **transcript'te var** (doğrulandı: 5 kayıt), ama izin/plan-onay yok. Seçeneklerin **her zaman** eksiksiz bulunduğu tek yer terminal ekran-buffer'ıdır.

**Çözüm (kullanıcı onaylı):** Terminal ekran-buffer'ını çıktı sessizliğinde tarayıp interaktif promptu (soru metni + tam seçenek listesi) çıkar; mevcut mobil `question` kartına normalize et. Cevap yolu değişmez (telefon zaten 1/2/3/Enter/Esc tuşu gönderiyor).

## Kararlar (kullanıcı onaylı)

- **K1 — Evrensel tek kaynak:** Ekran-scraper, "ekranda seçim bekleyen prompt var mı" sorusunun tek dedektörüdür; AskUserQuestion + izin + plan-onay hepsini kapsar. Transcript'in `AskUserQuestion` yolu yalnız **fallback**tır (oturum view-attached değilse / scanner erişilemezse).
- **K2 — Tetikleme:** Çıktı ~350 ms durunca (quiescence debounce, mevcut Codex 3 sn silence timer'ından ayrı). Her sessizlikte yeniden taranır; **son sonuçtan farklıysa** emit (var→payload / kalktı→nil).
- **K3 — Normalize hedefi:** Çıktı mevcut `question` mobil olayına/kartına map edilir (`Question{header, question, options}`). Yeni mobil UI yok.
- **K4 — Salt-okuma:** Scanner emülatörü yalnız okur (`getLine(...).translateToString`); PTY→UI ack/backpressure yoluna dokunmaz, replay/inject etmez.

---

## Bileşen 1 — Parser (`LumiTerminal/Parsing/TerminalPromptScanner.swift`) — YENİ

Saf, bağımsız test edilebilir. SwiftTerm/UI bağımlılığı **yok**.

```swift
public struct DetectedPrompt: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case permission, question, plan, generic }
    public let kind: Kind
    public let questionText: String?     // seçeneklerin üstündeki soru/başlık; yoksa nil
    public let options: [String]         // ekranda görüldüğü sırayla seçenek etiketleri
}

enum TerminalPromptScanner {
    /// Görünür alt satırlar (üstten alta) + cursor satırı → prompt veya nil.
    static func scan(lines: [String], cursorRow: Int) -> DetectedPrompt?
}
```

Algılama kuralları (girdi: `translateToString(trimRight:true)` ile alınmış düz satırlar):

- **Footer imzası (birincil sinyal):** son ~5 satırdan biri şunlardan birini içerirse
  `to select`, `to navigate`, `to proceed`, `esc to cancel`, `tab to amend`, `↑/↓` → prompt kabul.
  Bu Claude Code'un kendi menülerini (AskUserQuestion/izin) yakalar.
- **Footer'sız kural (2026-08, üçüncü-parti CLI menüleri — kullanıcı onaylı):** footer yoksa
  prompt yalnızca şu koşulların **hepsi** sağlanırsa kabul edilir (yoksa `nil`): (a) ≥2 seçenek,
  (b) numaralar 1'den **ardışık** (`[1,2,…,n]`), (c) **sarılan-satır yok** (temiz numaralı blok),
  (d) blok ekranın **en altına yaslı** (son seçenekten sonra yalnız boş satır). Bu, `cm` SSO login
  gibi footer'ı olmayan gerçek PTY menülerini yakalar; normal çıktının (log/liste) false-positive'ini
  eler. Kind = `generic`. *Sınır:* menü Claude'un kendi Bash tool'u içinde çalışıyorsa ekran-buffer'da
  olmadığından yakalanamaz — o durumda §K3 (ham ekran özeti) devreye girer.
- **Numaralı seçenekler:** `^\s*[❯›>\*]?\s*(\d+)\.\s+(.+)$` eşleşen ardışık satırlar. `❯/›/>` prefiksi seçili satırı işaretler (bilgi amaçlı; UI'ı etkilemez). Numaralı satır yoksa → `nil`.
- **Sarılan seçenek:** iki numaralı satır arasındaki, numarayla başlamayan boş-olmayan satırlar bir önceki seçeneğe (boşlukla) eklenir. **Yalnız kutu-çizgi karakterlerinden oluşan ayraç satırları** (`──────`, Claude AskUserQuestion şıklar-arası kural) sarılan-devam sayılmaz; atlanır (yoksa "Type something ──────" gibi kirlenir).
- **Soru metni:** ilk numaralı seçeneğin üstündeki, kutu-çizgi/boşluk temizlenmiş boş-olmayan satırlar (ilk boş satıra / buffer başına kadar), tek metne birleştirilir. Yoksa `nil`.
- **Kind sınıflandırması (best-effort, sadece etiket/başlık için):**
  `question` (footer `to select`/`to navigate` içerir → AskUserQuestion menüsü),
  `permission`/`plan` (footer `to proceed`/`Do you want to proceed`),
  aksi `generic`. Yanlış sınıflandırma davranışı bozmaz; yalnız kart başlığını etkiler.

Kenar durumlar: seçim vurgusu renk-only ise metinden görülmez (yalnız seçenekler listelenir — yeterli). Multi-select kutucukları (`□/☑`) seçenek metnine dahil edilir; seçim yine tuşla (kapsam dışı). "Type something"/"Chat about this" satırları ekranda numaralı göründükleri gibi seçenek olarak geçer.

## Bileşen 2 — Yakalama + tetikleme (`LumiTerminal`)

### TerminalSession (`Session/TerminalSession.swift`) — @MainActor
- Yeni salt-okuma yardımcı:
  ```swift
  @MainActor func captureBottomLines(_ n: Int = 16) -> (lines: [String], cursorRow: Int) {
      let t = terminalView.getTerminal()
      let rows = t.rows
      let start = max(0, rows - n)
      var out: [String] = []
      for r in start..<rows { out.append(t.getLine(row: r)?.translateToString(trimRight: true) ?? "") }
      return (out, t.getCursorLocation().y - start)
  }
  ```
- Yeni delegate metodu: `session(_:didDetectPrompt: DetectedPrompt?)` (nil = prompt kalktı).

### TerminalPipeline (`Session/TerminalPipeline.swift`)
- Yeni quiescence debounce (`PromptScanDebounce`, ~350 ms), her `deliver`/flush'ta yeniden arm edilir. Mevcut `CodexSilenceTimer`'dan **ayrı** (o 3 sn, durum içindir).
- Debounce ateşleyince: MainActor'a hop → `session.captureBottomLines()` → `TerminalPromptScanner.scan(...)` → sonucu **son gönderilenle diff**le → farklıysa `didDetectPrompt(result)` çağır. (Diff, sabit ekranda tekrar-emit'i önler.)
- Oturum terminate / replay-hydration sırasında tarama yapılmaz (canlı-mod guard).

### TerminalSessionManager + TerminalEvent
- `TerminalEvent`'e yeni case: `case promptChanged(TerminalID, DetectedPrompt?)`.
- `session(_:didDetectPrompt:)` → `broadcaster.send(.promptChanged(session.id, prompt))` (registered guard, mevcut `awaitingDecisionChanged` kalıbı).

## Bileşen 3 — Mac→telefon (`LumiRemote`)

### RemoteService (`RemoteService.swift`)
- Yeni alan: `private var screenPrompt: [TerminalID: DetectedPrompt] = [:]`.
- `handleTerminalEvent`'e yeni case:
  ```swift
  case .promptChanged(let id, let prompt):
      screenPrompt[id] = prompt
      guard let meta = terminal.terminals.first(where: { $0.id == id }) else { return }
      await connection.send(type: "event",
          payload: SnapshotBuilder.promptEvent(sessionId: meta.id.description, prompt: prompt))
  ```
- **Dedup (K1):** `handleFeedItem`'da transcript'ten `.question` gelirse, o oturumda `screenPrompt[id] != nil` ise **düşür** (ekran-scrape birincil). `screenPrompt[id] == nil` iken transcript `.question` fallback olarak geçer.
- `stopWatcher`/exit temizliğinde `screenPrompt[id] = nil`.
- `sendSnapshot`: aktif promptları snapshot'a geçir (aşağı).

### SnapshotBuilder (`SnapshotBuilder.swift`)
- Yeni saf yardımcı — prompt varsa `question` item, yoksa **temizleme** (boş options):
  ```swift
  static func promptEvent(sessionId: String, prompt: DetectedPrompt?) -> [String: Any] {
      let qs: [[String: Any]] = prompt.map { p in
          [["header": kindLabel(p.kind), "question": p.questionText ?? "", "options": p.options]]
      } ?? []                                  // nil → boş dizi = temizleme
      return ["kind": "transcript", "sessionId": sessionId,
              "item": ["itemType": "question", "questions": qs]]
  }
  ```
- `snapshot(...)`'a `activePrompts: [TerminalID: DetectedPrompt]` parametresi; her session entry'sine yalnız prompt varken `activePrompt: [Question-şekli]` alanı eklenir.

## Bileşen 4 — Protokol (`docs/spec/50-remote-protocol.md`, bağlayıcı)

- Mevcut `transcript`/`question` item'ı **iki anlam** taşır (belgelenir):
  - `questions` **boş değil** → prompt aktif; telefon kartı gösterir (ekran-scrape veya transcript AskUserQuestion).
  - `questions` **boş dizi (`[]`)** → prompt **kalktı**; telefon o oturumun kartını temizler. (Transcript yolu asla boş yollamaz; boş yalnız ekran-scrape temizliğinden gelir → çakışma yok.)
- Snapshot session şekline opsiyonel `activePrompt: [Question]?` alanı belgelenir (yok → prompt yok).

## Bileşen 5 — Mobil (`LumiMobileKit`)

Görüntüleme yolu **zaten var** (`activeQuestions` → `QuestionCardView` gerçek etiketlerle). Değişiklikler minimal:

### PhoneProtocol / AppModel
- `decodeFeedItem` "question" → `[Question]` (mevcut). **Boş dizi decode edilebilir kalır.**
- `AppModel.handle(.event(.transcript(sessionId, .question(qs))))`:
  ```swift
  if qs.isEmpty { activeQuestions[sessionId] = nil }   // YENİ: boş = temizle
  else { activeQuestions[sessionId] = qs }
  ```
- `SessionSummary`: yeni `public let activePrompt: [Question]?` (`decodeIfPresent`, yok → nil).
- `apply(snapshot:)`: `activePrompt` dolu session'lar için `activeQuestions[id] = activePrompt`; `liveIds` filtresi mevcut kalıpla.

`questionCard(for:)` önceliği aynen kalır: (1) `activeQuestions` = gerçek soru kartı ← ekran-scrape bunu besler ve **öncelik 1** olduğu için Spec 2'nin izin kartından üstündür. (2) `decisionPending` izin kartı = fallback (ekran-scrape erişilemezse Spec 2 davranışı korunur). (3) waiting jenerik.

## Mimari uyum (`docs/spec/00-overview.md §4`)

- **Backpressure/ack:** Scanner `feed()` tamamlandıktan sonra MainActor'da salt-okuma yapar; PTY→UI ack zincirine yeni yazma/inject yok.
- **Render-crash izolasyonu:** Parser saf/izole; buffer okuma read-only. Yakalama defensive (out-of-range → boş satır).
- **Replay güvenliği:** Tarama yalnız canlı modda; replay/hydration sırasında guard'lı (yanlış prompt üretmez).

## Hata yönetimi / kenar durumlar

- **Prompt→prompt değişimi:** yeni payload eskisinin üstüne yazılır (diff farklı → emit).
- **Prompt kalkması:** cevap → status `working`/`idle` → mobil `activeQuestions` zaten temizler; ek olarak ekran-scrape `nil` → boş `question` event → açık temizleme (Esc ile kapatıp waiting'de kalma gibi kenar durumu da kapsar).
- **Reconnect:** snapshot `activePrompt` taşır → ortada prompt varken bağlanan telefon kartı görür.
- **False positive:** footer imzası + numaralı seçenek; footer yoksa yukarıdaki 4 koşul (ardışık+temiz+alta-yaslı); normal çıktı/yarım render elenir.
- **Codex/diğer CLI:** imza jeneriktir; aynı footer+numara şeklini gösteren her CLI çalışır.
- **§K3 — ham ekran özeti (2026-08, kullanıcı onaylı):** oturum bekliyor (`awaitingDecision`/waiting) ama
  `scan()` yapısal prompt üretemiyorsa (parse edilemeyen menü), Mac son dolu ekran satırlarını
  (`TerminalPromptScanner.screenTail`, kutu-çizgi ayıklanmış, ≤6 satır) `screen_text` event'i /
  snapshot `screenText` alanıyla telefona yollar; telefon bunu bare "Oturum girdi bekliyor" kartının
  bağlamında gösterir (tool_use özetine yeğler). Yapısal prompt belirince Mac `[]` yollayıp temizler.
  *Sınır:* menü Claude'un kendi Bash tool'u içinde çalışıyorsa Lumi ekran-buffer'ında hiç bulunmaz →
  gösterilecek anlamlı metin yoktur (Claude Code sınırı, Lumi değil).

## Test

**LumiTerminal (`TerminalPromptScanner`) — çekirdek, TDD:**
- Gerçek fixture'lar (görünür-satır dizisi → beklenen `DetectedPrompt`): AskUserQuestion "Görsel adım" menüsü; skill-izin "Use skill artifact-design? 1.Yes 2.Yes-don't-ask 3.No"; plan-onay; Bash-izin.
- Sarılan seçenek satırı birleştirme; soru metni çıkarımı; kind sınıflandırması.
- Negatif: normal çıktı (footer yok), yarım render (footer var numara yok), boş ekran → `nil`.
- Pipeline: debounce sonrası tek emit; sabit ekranda tekrar-emit yok (diff); prompt kalkınca `nil` emit.

**LumiRemote:**
- `promptChanged(prompt)` → doğru `transcript/question` payload; `promptChanged(nil)` → boş `questions: []`.
- Dedup: `screenPrompt[id] != nil` iken transcript `.question` düşürülür; nil iken geçer.
- `snapshot(...)` prompt'lu session'a `activePrompt` koyar; prompt yoksa koymaz; exit temizler.

**LumiMobileKit:**
- `question` boş dizi → `activeQuestions[id] = nil`; dolu → set.
- `SessionSummary.activePrompt` var/yok decode (default nil); `apply(snapshot:)` doldurma + liveIds filtresi.
- `questionCard` önceliği: ekran-scrape sorusu izin kartından öncelikli.

**UI/manuel:** derleme (`swift test`, `xcodebuild ... build`); gerçek Lumi'de skill-izin promptu → telefonda **gerçek 1/Yes · 2/Yes-don't-ask · 3/No etiketli** kart → cevap → Mac ilerler; AskUserQuestion menüsü → tam şıklar.

## Dokunulan dosyalar

- **Yeni:** `LumiPackages/Sources/LumiTerminal/Parsing/TerminalPromptScanner.swift`; `DetectedPrompt` modeli (`LumiKit/Models`, LumiTerminal+LumiRemote paylaşır).
- `LumiPackages/Sources/LumiTerminal/Session/TerminalSession.swift`
- `LumiPackages/Sources/LumiTerminal/Session/TerminalPipeline.swift`
- `LumiPackages/Sources/LumiTerminal/Session/TerminalSessionManager.swift` (+ `TerminalEvent` tanımı, `LumiKit/Models/TerminalModels.swift`)
- `LumiPackages/Sources/LumiRemote/RemoteService.swift`
- `LumiPackages/Sources/LumiRemote/SnapshotBuilder.swift`
- `docs/spec/50-remote-protocol.md`
- `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/Models.swift`
- `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PhoneProtocol.swift`
- `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift`
- İlgili testler (LumiTerminalTests, LumiRemoteTests, ProtocolTests, AppModelTests)
