# Mobil chat UX cilası (orca paritesi) — tasarım

Tarih: 2026-09-20
Branch: `feat/remote-orca-main`
Kapsam: Lumi iOS (`LumiMobile`) native chat görünümü.

## Amaç

`MobileChatView` chat UX'ini orca (`mobile/src/session/MobileNativeChatView.tsx`,
`MobileNativeChatMessage.tsx`) paritesine yaklaştırmak. İki özellik:

1. **Scroll-to-bottom FAB + kapılı (gated) otomatik kaydırma**
2. **Asistan mesajlarında satır içi Copy ikonu**

"Eski mesajları yükle" **bilinçli olarak kapsam dışı** (YAGNI): Lumi'de tüm geçmiş
zaten `chatBySession[sessionId]` içinde bellekte ve `LazyVStack` tembel çizdiği için
orca'daki fetch-tabanlı sayfalamaya gerek yok. Asıl konfor kazancı FAB + gated
autoscroll'dan gelir. Gerekirse ayrı bir işte eklenir.

## Mevcut durum

`LumiMobile/App/MobileChatView.swift`:
- `ScrollViewReader` + `ScrollView` + `LazyVStack`, en altta `Color.clear.id("bottom")` sentinel'i.
- İki `onChange` (`turns.count` ve `model.gatedStreaming[sessionId]`) **her** değişimde
  koşulsuz `proxy.scrollTo("bottom")` yapıyor → kullanıcı geçmişi okurken bile aşağı
  zıplatılıyor (asıl sorun).
- FAB yok, kopyala butonu yok (yalnız `.textSelection(.enabled)`).

`LumiMobile/App/MobileChatMessageView.swift`:
- Asistan metni baloncuksuz düz prose; kullanıcı metni accent baloncuk. İkisi de
  `.textSelection(.enabled)`.

Veri tipleri: `ChatMessage` / `ChatBlock` → `LumiWire`; `FoldedTurn` / `foldChatMessages`
→ `LumiMobileKit` (`ChatFold.swift`). Bu sayede saf yardımcılar LumiMobileKit'te test
edilebilir.

Hedef platform: iOS 17.0 (min). `onScrollGeometryChange` iOS 18'dir → **kullanılamaz**;
iOS 17-güvenli geometri yaklaşımı gerekir.

## Feature A — Scroll-to-bottom FAB + gated autoscroll

Orca kuralı: otomatik kaydırma **yalnız kullanıcı zaten en alta yakınken** yapılır;
değilse bir "en alta git" FAB'ı gösterilir.

### At-bottom algılama (iOS 17-güvenli)
- `ScrollView`'a adlandırılmış koordinat uzayı verilir (`.coordinateSpace(name: "chatScroll")`).
- Alttaki sentinel (`Color.clear.id("bottom")`) bir `GeometryReader` ile sarılır ve
  `frame(in: .named("chatScroll")).minY` değerini bir `PreferenceKey` üzerinden yukarı
  bildirir.
- Dış `GeometryReader` zaten viewport yüksekliğini (`geo.size.height`) veriyor.
- Saf karar yardımcısı (LumiMobileKit):
  ```
  func chatAtBottom(sentinelMinY: CGFloat, viewportHeight: CGFloat, threshold: CGFloat = 80) -> Bool
  ```
  Kural: sentinel viewport'un alt kenarına `threshold` kadar mesafede veya daha yakınsa
  (`sentinelMinY <= viewportHeight + threshold`) at-bottom kabul edilir. Eşik `80`
  (orca `distanceFromBottom < 80` paritesi).
- View: `@State private var atBottom = true`. Preference değişiminde `atBottom`
  `chatAtBottom(...)` ile güncellenir.

### Gated autoscroll
- Mevcut iki `onChange` handler'ı yalnız `atBottom == true` iken `proxy.scrollTo("bottom")`
  yapar.

### FAB
- `arrow.down.circle.fill` butonu, liste alanının sağ-alt köşesinde `overlay` olarak.
- Yalnız `!atBottom` iken görünür (basit fade geçişi kabul).
- Dokunuş: `withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }` + `atBottom = true`.
- Okunmamış rozeti / sayaç **yok** (YAGNI).

## Feature B — Asistan mesajlarında satır içi Copy ikonu (orca paritesi)

### Saf yardımcı (LumiMobileKit)
```
func chatCopyText(_ turn: FoldedTurn) -> String?
```
- `turn.message.blocks` içindeki `.text` bloklarını sırayla birleştirir (satır sonuyla),
  tool-call / tool-result bloklarını atlar.
- Sonuç boşsa `nil` (buton çizilmez).

### UI (`MobileChatMessageView`)
- Yalnız asistan turn'lerinde (`turn.message.role == .assistant`) ve `chatCopyText` nil
  değilse: mesajın sağ-üstünde küçük bir kopyala ikonu (`doc.on.doc` veya orca'daki gibi
  ince bir ikon, `.secondary` tonu).
- Dokunuş: `UIPasteboard.general.string = text`, ardından ikon 700 ms boyunca onay
  ikonuna (`checkmark`) döner, sonra geri.
- Kullanıcı baloncukları yalnız `.textSelection` ile kalır (orca yalnız asistan prose'unu
  kopyalar; kullanıcı metni kısa ve zaten seçilebilir).

## Test

Saf mantık LumiMobileKit'te birim testi alır; SwiftUI/geometri yapıştırıcısı test edilmez.

- `chatAtBottom`:
  - eşik altında (yakın) → `true`
  - tam eşikte → `true`
  - eşik üstünde (uzak) → `false`
  - farklı viewport yükseklikleri
- `chatCopyText`:
  - yalnız-metin turn → birleşik metin
  - metin + tool karışık → yalnız metin
  - yalnız-tool turn → `nil`
  - çok metin-bloklu → satır sonuyla birleşik

## Dokunulacak dosyalar

- `LumiMobile/App/MobileChatView.swift` — PreferenceKey + at-bottom state + gated
  autoscroll + FAB overlay.
- `LumiMobile/App/MobileChatMessageView.swift` — asistan copy ikonu + copied state.
- `LumiMobile/LumiMobileKit/Sources/LumiMobileKit/ChatFold.swift` (veya yeni
  `ChatScrollGate.swift` / `ChatCopy.swift`) — `chatAtBottom`, `chatCopyText`.
- `LumiMobile/LumiMobileKit/Tests/LumiMobileKitTests/` — yeni test dosyası
  (`ChatScrollGateTests.swift` / `ChatCopyTests.swift`).

## Kapsam dışı

- Eski mesajları yükle / sayfalama (fetch).
- Kullanıcı mesajlarında copy butonu.
- FAB okunmamış rozeti.
- Kod bloğu / mesaj başına ayrı "kopyala" (yalnız turn prose'u).
