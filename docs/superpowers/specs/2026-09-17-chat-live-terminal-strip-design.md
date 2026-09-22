# Chat Canlı Terminal Şeridi + Düz Assistant Metni + Sığan Soru Kartı — Tasarım

Tarih: 2026-09-17 · Branch: `feat/remote-orca-main` · Durum: kullanıcı onayladı

## Problem

Telefon chat ekranında üç UI sorunu:

1. **Akış token-token gelmiyor.** Chat aynası Claude transcript JSONL'inden beslenir ve
   Claude, AskUserQuestion cevaplanana kadar transcript'i **hiç yazmaz** (2026-09-17'de
   TUI + `script` ile kanıtlandı: soru ekranda, JSONL diskte yok). Bu yüzden soru-öncesi
   assistant metni ancak option cevaplandıktan sonra görünür. Bu render sorunu değil,
   veri kaynağı sorunudur — transcript-only ayna bu metni prensipte gösteremez.
2. **Balon gereksiz.** Kullanıcı assistant metnini balonsuz, terminal-benzeri akışta istiyor.
   (Orca paritesi de bu: kullanıcı mesajı sağda balon, assistant metni düz prose.)
3. **Uzun soru ekrana sığmıyor.** `MobileChatPromptCard` sabit VStack; içinde scroll yok,
   uzun soru + çok seçenek ekranı aşıyor.

Orca'nın kendi çözümü (mobil native chat = `stream-json` structured child + journal)
Lumi'nin "terminal tek kaynak" mimarisiyle çelişir; kullanıcı bunun yerine **canlı
terminal şeridi** yaklaşımını seçti (AskUserQuestion ile onaylandı).

## Karar: Canlı terminal şeridi

Turn çalışırken **veya** pending prompt varken, chat ekranında mesaj listesi ile prompt
kartı arasında sabit yükseklikte, salt-okunur, canlı bir terminal alanı görünür. Veri
kaynağı telefonun terminal modunda zaten kullandığı PTY feed'idir (scrollback + data
frame'leri). Turn bitince (working=false ve pending prompt yok) şerit kaybolur; o anda
transcript flush edildiği için tamamlanmış mesajlar listeye yerleşir.

Kazanımlar: gerçek token-token akış; blokede bile soru-öncesi metin görünür; sıfır
ekran-scraping; sıfır yeni frame tipi (relay değişmez).

## Bileşenler

### A. Mac — chat aboneliği feed'i de yayınlar (`RemoteService.handleSubscribe`)

Bugün `mode=chat` yalnız chat/chat_status/prompt frame'leri başlatır. Değişiklik:
`mode=chat` dalı, terminal modundaki feed emisyonunu da başlatır — `seqCounters[id]=0`,
scrollback frame'i (seq=0, otoriter cols/rows), `terminal.subscribeOutput(id)` →
`emitData` task'ı (`subscriptions[id]`). Chat dalının her iki kolunda da geçerli
(claudeSessionID'li normal kol **ve** claudeSessionID'siz `awaitTranscript` kolu — ikisi
de PTY'li Lumi oturumudur). `meta` yoksa (oturum bilinmiyor) bugünkü gibi hiçbir şey
yayınlanmaz. Unsubscribe/stop mevcut `cancelSubscription` + `cancelChatSubscription`
ile ikisini de keser (bugünkü davranış korunur, test kilitler).

### B. iOS Kit — `AppModel` chat modunda feed rotası + şerit görünürlük kuralı

- `subscribeChat(_:)`, `subscribe(_:)` ile aynı feed hazırlığını yapar: eski oturumun
  sink/replay temizliği, `replayBuffers[sessionId] = []` (erken gelen scrollback şerit
  mount olmadan düşmesin). Chat frame işleme aynen kalır.
- Yeni yayınlanmış türetilmiş durum: `hasFeed(_ sessionId:) -> Bool` — o oturum için en
  az bir scrollback/data chunk'ı geldi mi (`route` sırasında işaretlenir; oturum
  listeden düşünce temizlenir). Dış (PTY'siz) oturumlarda hep false kalır.
- Saf görünürlük kuralı (test edilebilir, LumiMobileKit):
  `chatLiveStripVisible(working: Bool, hasPendingPrompt: Bool, hasFeed: Bool) -> Bool`
  = `(working || hasPendingPrompt) && hasFeed`.
- Scrollback'in otoriter grid boyutu yayınlanır: `gridSize(_ sessionId:) -> (cols: Int, rows: Int)?`
  (şeridin alt-bölge kırpması için).

### C. iOS App — şerit UI (`MobileChatView` + yeni `ChatLiveTerminalStrip`)

- Mesaj listesi ile prompt kartı arasında, görünürlük kuralı true iken `ChatLiveTerminalStrip`.
- Şerit, mevcut `TerminalHostView` + `TerminalFeedBuffer` + `model.terminalStream(sessionId)`
  üçlüsünü salt-okunur kullanır (`onInput` yok sayılır; `MirrorTerminalView` zaten
  first-responder olmaz).
- **Alt bölge görünür:** ayna emülatörü Mac'in cols/rows grid'inde kalır; şerit,
  grid yüksekliğindeki terminal view'ını alta hizalayıp (`ZStack(alignment: .bottom)`
  + `.clipped()`) sabit şerit yüksekliğine (220pt) kırpar — en güncel içerik (spinner,
  akan metin, soru) hep görünür. Grid yüksekliği `rows × terminal fontunun lineHeight'i`
  ile yaklaşıklanır; birkaç puntoluk sapma kabul edilir (kırpma alttan hizalı olduğu
  için içerik kaybolmaz). Cihazda görsel doğrulama yapılır.
- Şerit görünürken chat listesi auto-scroll davranışı bugünkü gibi kalır.

### D. iOS App — balon kaldırma (`MobileChatMessageView`)

Assistant text blokları balonsuz düz metin olur: arka plan yok, tam genişlik, sola
hizalı, `Color.primary`. Kullanıcı mesajı bugünkü gibi sağda accent balonda kalır.
Araç satırları (toolCall/toolResult) aynen kalır.

### E. iOS App — soru kartı taşması (`MobileChatPromptCard`)

Kart gövdesi (başlık + detail + seçenekler/sorular + free-text) bir `ScrollView`'a
alınır ve yükseklik ekranın ~%45'i ile sınırlanır (`maxHeight`). Soru metni hiçbir
yerde kısaltılmaz (tam sarılır; mevcut `detail` için 2 satır + middle-truncation
korunur — o bir komut önizlemesidir). Gönder/Allow-Deny butonları scroll içeriğinin
parçasıdır; kart sınırı sayesinde composer her zaman ekranda kalır.
Tek/çok-soru, multiSelect, allowOther davranışları değişmez.

## Veri akışı (özet)

```
Mac PTY ──subscribeOutput──▶ RemoteService ──scrollback/data──▶ relay ──▶ telefon
                             (artık mode=chat'te DE)             AppModel.route
                                                                    │
Claude transcript ──chatSource──▶ chat/chat_append ──▶ chatBySession│
Hook'lar ──▶ chat_status / prompt ────────────────────────▶ turnStatus/prompts
                                                                    ▼
                          MobileChatView: mesajlar + [şerit (canlı PTY)] + kart + composer
```

## Hata durumları

- **PTY'siz dış oturum:** feed hiç gelmez → `hasFeed=false` → şerit hiç görünmez;
  chat bugünkü gibi çalışır (zarif düşüş).
- **Feed kesilirse** (Mac offline): şerit son ekran içeriğinde donar; `macOnline=false`
  banner'ı mevcut davranışıyla bilgilendirir. Ek işlem yok.
- **Bant genişliği:** chat modunda feed eklemek terminal moduyla aynı hacimdir; relay
  passthrough, backpressure mevcut ack mekanizmasıyla aynı.

## Test stratejisi

- Mac (`LumiRemoteTests`): mode=chat subscribe → gönderilen frame'ler arasında
  `scrollback` VE PTY çıktısında `data` var; `unsubscribe` sonrası data kesilir;
  claudeSessionID'siz kolda da scrollback gelir.
- iOS Kit (`LumiMobileKitTests`): `subscribeChat` sonrası gelen scrollback
  `terminalStream`'den akar; `hasFeed` bayrağı; `chatLiveStripVisible` doğruluk tablosu;
  `gridSize` scrollback cols/rows'unu yansıtır.
- iOS App: derleme (`xcodegen generate` + `xcodebuild`); şerit alt-bölge kırpması ve
  kart scroll'u cihazda görsel doğrulama.

## Kapsam dışı

Relay, `PromptJournal`, Mac desktop UI, stream-json structured child, feed'in chat
moduna özel inceltilmesi (satır filtreleme/scraping yok).
