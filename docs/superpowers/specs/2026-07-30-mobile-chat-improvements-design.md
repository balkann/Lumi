# Tasarım: Mobil Chat İyileştirmeleri (Spec 1)

Tarih: 2026-07-30
Durum: Onay bekliyor

## Bağlam

LumiMobile (iOS, SwiftUI + LumiMobileKit) oturum detayında chat deneyimi üç sebeple zayıf:

1. Kullanıcının gönderdiği mesajlar feed'de hiç görünmüyor (`AppModel.sendText` feed'e dokunmuyor; transcript hiçbir zaman kullanıcı metni üretmez — `itemType`'lar yalnız `assistant_text`/`tool_use`/`question`/`turn_done`).
2. Enter'a basınca gönderim olmuyor (`TextField(axis: .vertical)` → Enter = yeni satır; gönderme yalnız butonla) ve gönderimin gidip gitmediğine dair geri bildirim yok.
3. Chat/oturum silme yok.

Bu spec bu üçünü çözer. **Kapsam dışı** (kendi spec'lerinde): izin promptu görünürlüğü (Spec 2) ve çalışan model seçici (Spec 3).

## Roadmap (bağlam)

- **Spec 1 (bu doküman):** gönderilen mesaj görünürlüğü + gönderim durumu, Enter=gönder, gerçek chat silme.
- **Spec 2:** tool-use izin promptu görünürlüğü — yaklaşım C (jenerik "bekliyor" kartını güçlendir; ANSI parse yok).
- **Spec 3:** oturum detayında çalışan modeli gösterme + seçici (protokol + Mac işi).

## Kararlar (kullanıcı onaylı)

- Enter = **gönder** (çok-satırlı giriş bırakılır; sohbet normu).
- Chat silme = **gerçek silme** (Mac'te oturumu sonlandır). Yeni `delete_session` protokol action'ı gerektirir.
- Silme UI'ı = **yalnızca `SessionListView`'da swipe-to-delete + onay**.
- Başarısız gönderim = **dokununca tekrar dene**.

---

## Bileşen 1 — Gönderilen mesaj görünürlüğü + gönderim durumu

Kullanıcı mesajları yalnız telefonda yaşar (transcript'te yok), bu yüzden **iyimser (optimistic)** olarak feed'e eklenir ve komut sonucuna göre durum güncellenir.

### Model (`LumiMobileKit/Models.swift`)

```swift
public enum SendStatus: Sendable, Equatable { case sending, sent, failed }

public enum FeedItem: Sendable, Equatable {
    case assistantText(String)
    case toolUse(tool: String, summary: String)
    case question([Question])
    case turnDone
    case userMessage(text: String, status: SendStatus)   // YENİ — yalnız yerel
}
```

`PhoneProtocol.decodeFeedItem` bu case'i **asla üretmez** (gelen taraf toleransı korunur).

### AppModel (`LumiMobileKit/AppModel.swift`)

- Yeni alan: `private var commandUserMessages: [String: Int] = [:]` — `commandId → FeedEntry.id`.
- `sendText(sessionId:text:)`:
  1. `text`'i trim'le; boşsa no-op.
  2. `.userMessage(text, .sending)` entry'sini feed'e ekle, yeni entry `id`'sini yakala.
  3. Komutu dispatch et; üretilen `commandId`'yi entry id'sine eşle (`commandUserMessages`).
- `command_result` işleme:
  - `commandUserMessages[commandId]` varsa: `ok` → o entry'nin status'unu `.sent`, `!ok` → `.failed` yap; eşlemeyi kaldır. **Bu durumda `lastCommandError` yazılmaz** (baloncuk durumu tek geri bildirim; press_key gibi diğer komutlar eski davranışı korur).
- Bağlantı-yok yolu (`client.send` false): eşlenen entry `.failed`.
- `retrySend(sessionId:entryId:)`: `.failed` baloncuğa dokununca entry'yi `.sending`'e çevirir, yeni `commandId` ile tekrar dispatch eder, yeniden eşler.
- `applyHistory` **koruma**: history feed'i replace ederken mevcut `.userMessage` entry'leri korunur (transcript'te olmadıkları için, id/status'larıyla history öğelerinin **sonuna** yeniden eklenir; `feedCap` uygulanır). Böylece oturuma geri dönünce gönderilen mesajlar kaybolmaz.

### UI (`SessionDetailView.swift` → `FeedEntryView`)

- `.userMessage(text, status)` → **sağa hizalı baloncuk** (accent renk zemin). Sağ altta durum ikonu:
  - `.sending` → küçük saat/`ProgressView`,
  - `.sent` → soluk ✓,
  - `.failed` → kırmızı ⚠︎, dokunulabilir → `retrySend`.

---

## Bileşen 2 — Enter = gönder

`SessionDetailView.inputBar`:

- `TextField`'dan `axis: .vertical` ve `lineLimit(1...4)` kaldırılır (tek satır).
- `.submitLabel(.send)` + `.onSubmit { send() }` eklenir (klavyede "Gönder" tuşu; Enter mesajı yollar).
- `send()` yardımcısı çıkarılır (buton ve onSubmit paylaşır): draft'ı yakala, temizle, `Task { await model.sendText(...) }`. Boş/whitespace ise no-op.
- Gönder butonu korunur (mevcut disable koşullarıyla).
- Gönderimde hafif haptic (opsiyonel, `UIImpactFeedbackGenerator`).

Kaydırma: yeni entry'de mevcut `onChange(of: feed.last?.id)` zaten en alta kaydırıyor — iyimser baloncuk anında en altta görünür (responsiveness geri bildirimi).

---

## Bileşen 3 — Gerçek chat silme (stack-wide)

### Protokol (`docs/spec/50-remote-protocol.md` — bağlayıcı, implementasyonda güncellenir)

Giden komutlara eklenir:
- `delete_session {commandId, sessionId}` — oturumu Mac'te sonlandırır. Hata: `session_not_found`.

### Mac (`LumiPackages/Sources/LumiRemote/RemoteCommandHandler.swift`)

`handle(_:)` switch'ine yeni case:

```swift
case "delete_session":
    return result(commandId, run: {
        let id = try self.session(from: payload)
        try self.terminal.kill(id: id)
    })
```

`terminal.kill(id:)` (`TerminalServicing`'de mevcut) → `.exited` event → mevcut `RemoteService` akışı `stopWatcher` + `sendSnapshot()` yayınlar → oturum telefon listesinden düşer. Ek Mac değişikliği gerekmez.

### Mobil

- `PhoneProtocol`: `CommandAction.deleteSession(sessionId:)`; `commandFrame` → `action: "delete_session"`, `sessionId`.
- `AppModel.deleteSession(sessionId:)` → `dispatch(target: sessionId, action: .deleteSession(...))`. Kaldırma snapshot ile gelir (iyimser yerel kaldırma yok — tek doğruluk kaynağı Mac snapshot'ı).
- UI (`SessionListView`): `ForEach` üzerinde swipe action (destructive "Sil") → `@State pendingDelete: SessionSummary?` → `.alert`/`.confirmationDialog` "Oturum sonlandırılsın mı?" (yıkıcı) → onayda `model.deleteSession`.

---

## Hata yönetimi

- Gönderim: başarısızlık baloncuk durumuna yansır (kırmızı ⚠︎ + tekrar dene). `lastCommandError` send_text için kullanılmaz.
- Silme: `session_not_found` veya bağlantı-yok → oturum listede kalır (snapshot değişmez). v1'de sessiz; ileride toast eklenebilir.
- Protokol decode toleransı korunur: bilinmeyen action/item akışı kırmaz.

## Test

**LumiMobileKitTests (AppModelTests):**
- `sendText` → feed'e `.userMessage(.sending)` ekler ve `commandId` eşler.
- `command_result` `ok` → `.sent`; `!ok` → `.failed`; send_text'te `lastCommandError` yazılmaz.
- `client.send` false → eşlenen entry `.failed`.
- `applyHistory` mevcut `.userMessage` entry'leri korur (history sonrası tail'de, sırayla).
- `retrySend` → `.failed`'i `.sending`'e çevirir + yeni komut dispatch eder.
- `deleteSession` → `delete_session` action'ı dispatch eder.

**ProtocolTests:**
- `commandFrame(.deleteSession)` → `{action:"delete_session", sessionId, commandId}` round-trip.

**LumiRemote (RemoteCommandHandler testleri):**
- `delete_session` → `terminal.kill(id:)` çağrılır, `ok:true`.
- Bilinmeyen/eksik sessionId → `session_not_found`.

## Dokunulan dosyalar

- `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/Models.swift`
- `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/AppModel.swift`
- `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/PhoneProtocol.swift`
- `LumiMobile/App/SessionDetailView.swift`
- `LumiMobile/App/SessionListView.swift`
- `LumiPackages/Sources/LumiRemote/RemoteCommandHandler.swift`
- `docs/spec/50-remote-protocol.md` (bağlayıcı protokol güncellemesi)
- İlgili test dosyaları
