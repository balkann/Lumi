# Lumi Remote — Devir (Handoff) Dokümanı

**Tarih:** 2026-07-28
**Amaç:** Yeni bir sohbette bu dosyayı açıp kalan işlerden devam etmek. Önceki sohbet token doldu.

Bu dosyayı yeni sohbette şununla aç:
> "docs/superpowers/lumi-remote-HANDOFF.md dosyasını oku, Plan 3'ten devam edelim."

---

## Proje özeti

Lumi (macOS-native, çok-oturumlu Claude Code dashboard'u) telefondan yönetilebilsin diye 3 parçalık "Lumi Remote" özelliği ekleniyor. Mimari: **iOS app ⇄ WebSocket relay (Railway) ⇄ Mac'teki LumiRemote modülü**.

- Repo (fork): https://github.com/balkann/Lumi — lokal: `/Users/balkan/Lumi`
- Upstream (dokunma): berkaysazlioglu/Lumi
- Tasarım: `docs/superpowers/specs/2026-07-26-lumi-remote-design.md`
- **Protokol sözleşmesi (Plan 3 buna kodlanacak): `docs/spec/50-remote-protocol.md`** — zarf, mesaj tablosu, snapshot + transcript event payload şekilleri burada.

## Tamamlanan işler

**Plan 1 — RelayServer** ✅ (fork main'de, Railway'de canlı)
- Node.js/TS WebSocket relay: `RelayServer/`
- Canlı: `wss://lumi-relay-production.up.railway.app` (Railway projesi `lumi-relay`, hesap alknberkant@gmail.com, Hobby plan)
- APNs push altyapısı var ama **env değişkenleri girilmedi** → şu an `NoopPushSender` (Plan 3'te doldurulacak).

**Plan 2 — LumiRemote (Mac modülü)** ✅ (fork main'de)
- `LumiPackages/Sources/LumiRemote/`: RelayConnection, SnapshotBuilder, TranscriptParser, TranscriptWatcher, RemoteCommandHandler, RemoteService, RemoteConfigService
- RemoteStore (LumiState), Ayarlar "Remote" tab'ı + QR (LumiUI), AppContainer DI
- Tam suite: **444 test, 0 uyarı**. Canlı relay'e karşı uçtan uca doğrulandı.
- Dev config: `~/.lumi-dev/remote.json` (enabled=true, canlı relay + token).
- Uçtan uca test istemcisi: `Scripts/fake-phone.mjs`

## KALAN İŞ — Plan 3/3: LumiMobile (iOS SwiftUI app + APNs)

Henüz plan yazılmadı. Yeni sohbette **önce `superpowers:writing-plans` ile Plan 3 yazılacak**, sonra `superpowers:subagent-driven-development` ile görev-görev yürütülecek (Plan 1 ve 2'deki akışın aynısı: her görev ayrı subagent + bağımsız inceleme + gerekirse düzeltme turu + sonda final tüm-branch incelemesi).

### Plan 3 kapsamı (tasarım §4.3 + spec'ten)
Yeni Xcode projesi `LumiMobile/` (repo içinde, monorepo kararı korundu). Üç ekran:
1. **Oturumlar** — repo adı + durum rozeti (idle/working/waiting/error); `waiting` olanlar üstte
2. **Oturum detayı** — transcript olay akışı (assistant_text / tool_use / question / turn_done); altta serbest metin kutusu; `question` gelince sabitlenmiş cevap kartı (1/2/3/enter/esc butonları + serbest metin)
3. **Yeni oturum** — repo listesi → (opsiyonel) persona → ilk prompt → gönder

Ayrıca:
- **Eşleştirme:** QR/deeplink `lumi-remote://pair?url=<pctEncoded>&token=<pctEncoded>` okut → token'ı iOS Keychain'e yaz. (Mac tarafı QR'ı Ayarlar → Remote'ta üretiyor.)
- **WebSocket istemcisi:** relay'e `role:"phone"` ile bağlan; `welcome` → snapshot'ı göster; `snapshot`/`event`/`command_result` mesajlarını işle; `command` (send_text/press_key/start_session), `register_push`, `ping` gönder. Zarf: `{"v":1,"type":...,"payload":{...}}`.
- **APNs:** device token'ı `register_push {deviceToken}` ile relay'e gönder. **Ücretli Apple Developer hesabı gerekli** (99$/yıl) — push için şart. Relay'e APNs env değişkenleri girilecek: `APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID` (Railway dashboard → Variables). Kendi telefonuna kurmak için ücretsiz hesap yeter ama 7 günde bir yeniden imzalama + push çalışmaz.

### Plan 3 başında netleştirilecek açık sorular
- Minimum iOS sürümü? (öneri: iOS 17+, modern SwiftUI/Observation için)
- Apple Developer hesabı hazır mı? Değilse push'suz başlanır (canlı akış app açıkken zaten çalışır), APNs sonraki faz.
- Xcode projesi mi yoksa SPM executable + XcodeGen mi? (öneri: normal Xcode projesi, `LumiMobile/`)
- Test yaklaşımı: view-model'ler için XCUnit; relay istemcisi için sahte-sunucu.

## Protokol hızlı referans (detay: docs/spec/50-remote-protocol.md)

- **hello** (phone→relay): `{role:"phone", token}` → **welcome**: `{snapshot, macOnline, lastSeenAt}`
- **snapshot** payload: `{sessions:[{id,repoPath,repoName,status,title?}], repos:[{name,path}], personas:[{id,label}]}`
- **event** payload, iki tür:
  - `{kind:"status_change", sessionId, status, repoName, summary?}`
  - `{kind:"transcript", sessionId, item:{itemType, ...}}` — itemType: `assistant_text{text}` / `tool_use{tool,summary}` / `question{questions:[{header,question,options[]}]}` / `turn_done`
- **command** (phone→relay): `{commandId, action, ...}` — action: `send_text{sessionId,text}` / `press_key{sessionId,key}` (key: 1|2|3|enter|esc) / `start_session{repoPath,personaId?,prompt}`
- **command_result** (relay→phone): `{commandId, ok, error?}`
- **register_push** (phone→relay): `{deviceToken}`

## Nasıl devam edilir (yeni sohbet)

1. Bu dosyayı ve `docs/spec/50-remote-protocol.md`'yi oku.
2. `superpowers:writing-plans` ile Plan 3'ü yaz → `docs/superpowers/plans/2026-07-28-lumi-remote-ios.md` (veya güncel tarih).
3. Yeni branch: `git checkout -b feature/lumi-remote-ios` (main'den).
4. `superpowers:subagent-driven-development` ile görev-görev yürüt. Ledger: `.superpowers/sdd/progress.md` (Plan 1+2 kayıtları orada).
5. Bitince `superpowers:finishing-a-development-branch` → fork main'e merge.

**Yürütme kalıbı (Plan 1/2'de kullanılan, işe yaradı):** kod planda tam yazılıysa implementer=haiku; entegrasyon/UI/eşzamanlılık görevleri=sonnet; incelemeler=sonnet; final tüm-branch incelemesi=fable (en yetkin). Her görev sonrası `scripts/review-package` + task-reviewer subagent; Critical/Important bulgular için düzeltme turu + re-review.

## Devredilen (deferred) Minor'lar — Plan 1+2'den, Plan 3 sırasında veya ayrı fast-follow'da ele alınabilir

- **TranscriptWatcher eşit-mtime oscillation:** aynı saniyede oluşan iki jsonl arasında her poll'da geçiş yapabilir (teorik; gerçekte her claude oturumu ayrı timestamp). Zarif degrade.
- **RemoteConfigService.save** yazma hatasını yutuyor (`try?`); `configDir` yazılamıyorsa her açılışta yeni token üretilir, eşleştirme sessizce bozulur. Bir kerelik toast/log iyi olur.
- **AppContainer termination'da `RemoteService.stop()` fire-and-forget** (async shutdown süreç çıkışıyla yarışır); relay'in 30s heartbeat'i kapatır ama `stop()`'u async yapıp `shutdown()`'da await etmek temiz olur.
- **Aynı repoda 2 eşzamanlı oturum** aynı en-yeni jsonl'e bağlanabilir (tasarım §12.1'de kabul edilmiş v1 riski); ihtiyaç olursa Claude Code Notification hook'uyla oturum-id eşlemesi eklenir.
- **pairingString kodlaması:** relay URL'inde query olursa iOS parse'ı karışabilir; token güvenli. Gerekirse daha sıkı charset.
- **RelayInbound `@unchecked Sendable`** — üretimsdeki tek eşzamanlılık kaçış-kapısı; gerekçeli (payload taze JSONSerialization dict) ama açıklayıcı yorum eklenebilir.
- **relayUrl draft** yalnız Enter'da kaydediliyor (power-user alanı, kabul edilebilir).

## Önemli komutlar

```bash
cd /Users/balkan/Lumi/LumiPackages && swift test          # tüm suite (444)
cd /Users/balkan/Lumi/LumiPackages && swift run Lumi       # Mac app (dev, ~/.lumi-dev)
node /Users/balkan/Lumi/Scripts/fake-phone.mjs <token>     # sahte telefon istemcisi (canlı relay)
```

Commit imzası: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
