# Faz 2 sonrası "sohbet yükleniyor" + mesaj gitmiyor — kırılma notu

Tarih: 2026-09-18 · Branch: `feat/remote-orca-main` · HEAD: `d67cfa1` (Faz 2 kapanışı)
Durum: **CANLI SORUN, düzeltilmedi.** Kullanıcı isteği: sorunu ve "neyi değiştirip bozduğumuzu" not et. Mac build'i kullanıcı onayı olmadan güncellenmeyecek ([[ask-before-mac-update]]).

## Belirti (kullanıcı)
- Yeni chat başlattı VE var olan chat'lere girdi → her ikisinde de ekran **"Sohbet yükleniyor…"**'da kalıyor.
- Composer'a yazdığı mesaj **gitmiyor** ("direk mesajım gitmiyor sanırım").

## Kanıt (iki log, Mac'e dokunmadan)
- **iOS** (`Documents/lumi-mobile.log`): `06:42:43 out ph-1 startSession ok=true` → `in commandResult ok=true` → `in sessions count=3` → `in chat count=0`. Sonrasında **hiç `out` giden mesaj/chat_send YOK**; yalnız relay kopma+reconnect (06:58:08) + app restart (06:58:44) + gelen `sessions/chat count=0`.
- **Mac** (`~/.lumi/logs/mac.log`): telefon `subscribe` frame'leri geliyor; **`chat_send` tüm logda 0 kez**, `input` 0 kez. Yani mesaj frame'i telefondan Mac'e HİÇ ulaşmıyor.
- Yeni chat child'ı canlı: `claude -p --output-format stream-json --session-id 9fc80785…` (PID vardı). Köprü kuruldu, `chat-bridge: initial snapshot count=0` gitti. Journal boş çünkü agent'a girdi gelmedi.
- "Var olan chat" diye açılanlar `1811F71D`, `F8CBD419` = **büyük-harf UUID = TERMINAL oturumları** (Mac restart'ında bellekteki chat oturumları silindiği için listede sadece terminaller kaldı). Mac bunlara `chat oturumu yok — boş chat + idle` döndü.

## Kök nedenler ve NEYİ DEĞİŞTİRİP BOZDUĞUMUZ

### 1. Terminal oturumları chat modunda çıkmaza düşüyor — REGRESYON (bizim değişiklik)
- Faz 2 T3'te terminal oturumları için **transcript-tail chat yolunu SÖKTÜK** (chat artık yalnız stream-json chat oturumu).
- AMA telefon tarafında `LumiMobile/App/TerminalSessionView.swift`'te `@State showChat = true` — **HER oturum varsayılan chat modunda açılıyor**; türe göre yönlendirme eklenmedi. T5 yalnız `NewSessionView`'ı chat başlatmaya çevirdi, oturum-açma yönlendirmesini değiştirmedi.
- Sonuç: terminal oturumu → chat modu → Mac "chat oturumu yok" → sonsuz "yükleniyor". Faz 2 öncesi bu oturumlar chat modunda transcript-tail içerik gösteriyordu; onu kaldırdık, yeniden yönlendirmedik → **kırdık**.

### 2. "Sohbet yükleniyor…" her boş chat'te görünüyor — yanıltıcı (pre-existing, artık sürekli tetikleniyor)
- `LumiMobile/App/MobileChatView.swift:23-27`: `if turns.isEmpty { Text("Sohbet yükleniyor…") }`. "yükleniyor" / "boş, yaz başlasın" / "terminal oturumu" ayrımı yok. Faz 2 öncesinden var ama artık (terminaller hiç dolmuyor, yeni chat boş başlıyor) sürekli görülüyor.

### 3. Yeni chat promptsuz başlıyor — yeni davranış (bizim değişiklik, T5)
- `AppModel.startChatSession(repoPath:)` prompt=`""` gönderiyor; `NewSessionView` prompt vermiyor. stream-json child girdi bekliyor, hiçbir şey üretmiyor → boş → "yükleniyor". Kullanıcı composer'a yazana kadar ekran boş.

### 4. Mesaj gönderme uçtan uca DOĞRULANMADI — açık teşhis noktası
- Composer doğru bağlı: `MobileChatView.composer` send → `model.submitText(sessionId, draft)`.
- `submitText` (AppModel.swift:348) chat/terminal ayrımı: `chatSessionIds.contains(sessionId) || sessions.first{…}?.kind=="chat"` → `chat_send`, aksi halde PTY `input`+CR.
- Mac NE `chat_send` NE `input` aldı; iOS logunda giden mesaj yok. `subscribe` frame'leri aynı transport'tan geliyor → transport çalışıyor. Öyleyse ya (a) composer send tetiklenmiyor (klavye altında kalan buton / erişilemezlik?), ya (b) submitText çağrıldı ama frame üretilmedi/gönderilmedi. **Mevcut loglar bunu ayırt edemiyor** — `submitText`'e bir DiagLog satırı ("out chat_send sid=… / out input sid=…") eklenmeli ki hangi dalın çalıştığı/çalışmadığı görülsün. Bu, tahminsiz bir sonraki adım.
- NOT: relay 06:58'de bir kez koptu ("Software caused connection abort") + app restart oldu; bağlantı kararsızlığı da mesajın kaybolma ihtimaline katkı olabilir ama subscribe'lar sonrasında ulaştığından birincil sebep bu değil.

## Önerilen düzeltme (Faz 2.1 — Mac + iOS güncellemesi gerektirir; kullanıcı onayı bekliyor)
1. **Türe göre yönlendirme:** `TerminalSessionView` (veya SessionList tıklaması) oturumun `kind`'ine baksın — terminal → varsayılan terminal-mirror, chat → chat görünümü. Terminal oturumu için ölü chat modu default olmasın.
2. **Boş-durum metni:** "Sohbet yükleniyor…" yerine: kurulmuş-ama-boş chat'te "Mesaj yaz, sohbet başlasın"; "yükleniyor"u yalnız ilk-frame öncesi kısa ana sakla. Terminal oturumu chat'e zorlanırsa açık uyarı.
3. **Gönderme teşhisi:** `submitText`'e DiagLog ekle (hangi dal + frame gönderildi mi) → cihazda tek denemeyle chat_send'in çıkıp çıkmadığını kanıtla; çıkmıyorsa composer/klavye erişilebilirliğini incele.
4. (Ops.) Yeni chat'te composer'a otomatik odak; istenirse ilk mesajı start ile gönder.

## Önemli ders
Faz 2 unit testleri submitText'i `sessions`'a `kind:chat` ENJEKTE ederek geçmişti → prod'da chat oturumunun listeye gerçekten girip girmediğini + composer→chat_send uçtan uca akışını maskeledi. **Enjeksiyonsuz, gerçek başlat→2. mesaj cihaz/entegrasyon doğrulaması olmadan "yeşil" güven vermiyor.** (Final review'ın yakaladığı Critical'in kardeşi.)
