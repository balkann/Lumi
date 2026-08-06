# Transcript Eşleşmesi — SessionStart Hook ile Deterministik Model (Tasarım)

Tarih: 2026-08-06
Branch: `spec/transcript-hook-matching` (`lumi-remote`'tan)
Durum: tasarım onaylandı; implementasyon planı bekliyor.

## 1. Problem

Lumi bir terminalin Claude Code transcript'ini `~/.claude/projects/<cwd-türevi>/<id>.jsonl`
dosyasını tail'leyerek telefona yansıtır. Bugünkü eşleşme (bkz. `TranscriptWatcher.resolveMatch`)
üç katmanlı: (1) enjekte edilen `--session-id` ile `<TID>.jsonl` (exactFile), (2)
`TranscriptClaimRegistry` birthtime≈createdAt tekil-sahiplik, (3) mtime sezgiseli.

Bu model üç durumda kırılıyor — hepsinin ortak kök nedeni: **Lumi'nin izlediği dosyanın
adı/konumu, oturumun gerçekte yazdığı dosyayla artık örtüşmüyor.** Belirti hep aynı:
telefonda **boş chat**, **giden mesaj çalışır** (PTY'ye TerminalID ile yazılır, eşleşmeden
bağımsız), **gelen/canlı transcript gelmez**.

1. **Worktree:** Oturum bir git worktree'ye geçince (cwd `.../.claude/worktrees/...`) Claude
   transcript'i worktree-türevi proje dizinine yazar; watcher repoPath-türevi dizine bakar.
2. **`/clear`:** Claude `/clear`'da yeni bir session-id ile **yeni dosya** açar, enjekte
   `--session-id` override edilir, geri-referans yoktur (doğrulandı: GH #37451). exactFile
   eski `<TID>.jsonl`'i işaret etmeye devam eder → bayat/durmuş içerik.
3. **Dış oturum:** Rider'dan / elle / `--resume` başlatılan claude Lumi'nin id'sini taşımaz;
   `<TID>.jsonl` hiç oluşmaz. Registry+mtime katmanları bu durumu "tahminle" doldurmaya
   çalışır → tab'lar arası sızma / yanlış eşleşme (crosstalk).

Registry+mtime katmanları, session-id enjeksiyonu olmadan önceki dönemin fallback'i. Sabit
`<TID>.jsonl` varsayımı yetersiz, tahmin katmanları kırılgan.

## 2. Hedefler / Hedef olmayanlar

**Hedefler**
- Worktree oturumları doğru yansısın (id var, sadece yanlış yere bakılıyor).
- `/clear` (ve `--resume`) transcript dosyası değişimi **deterministik** takip edilsin; `/clear`
  telefonda da yansısın (feed temizlenip yeni oturum yüklensin).
- Eşleşme **tahminsiz** olsun: registry + mtime sezgiseli tamamen kaldırılsın.
- Eşleşemeyen (Lumi-dışı/id'siz) oturum telefonda **açıkça "yansıtılamıyor"** gösterilsin,
  sessiz boş chat yerine.

**Hedef olmayanlar**
- Dış (Rider/elle) oturumları yansıtmak — kimlik bağı yok; kapsam dışı (kullanıcı kararı, bu tur).
- Kullanıcının global/proje Claude ayarlarını değiştirmek — `--settings` ile hiç dokunulmaz.
- `~/.lumi` mevcut JSON/YAML formatlarını değiştirmek (karar 9 korunur; yalnızca yeni dosyalar eklenir).

## 3. Kararlar (doğrulanmış olgulara dayalı)

Claude Code davranışı (claude-code-guide ile doğrulandı, v2.1.169+; sürüme bağlı olabilir):
- `SessionStart` hook'u **startup/resume/clear/compact/fork**'ta tetiklenir; `source` ayırt eder;
  `/clear`'da **yeni oturum aktifken** çalışır.
- Hook stdin JSON'u: `session_id`, **`transcript_path`** (o anki .jsonl mutlak yolu), `cwd`,
  `hook_event_name`, `source`.
- Hook subprocess'i **spawner env'ini miras alır** → PTY'de `LUMI_TERMINAL_ID` set edilirse
  hook `$LUMI_TERMINAL_ID` görür.
- `--settings <dosya|inline-json>` ayarları **merge** eder (CLI-arg önceliği; user/project/local
  üstünde), hook'lar **additive** birleşir (kullanıcının hook'ları ezilmez), şema her yerde aynı.
- `/compact` aynı dosyaya devam (sorun yok). `--fork-session` yeni dosya (SessionStart `fork`).
- fd sürekli açık değil (lsof güvenilmez), `CLAUDE_SESSION_ID`/lock/pointer yok — bu yüzden
  hook tek deterministik kaynak.

**Karar:** Lumi kendi `SessionStart` hook'unu **`--settings` ile** ekler (global config'e
dokunmadan); hook her oturum başında `{LUMI_TERMINAL_ID → transcript_path}` eşlemesini bir
pointer dosyasına yazar; watcher tahmin yerine bu pointer'dan **kesin dosyayı** okur.

## 4. Mimari

```
Lumi spawn: PTY(cwd=repoPath, env LUMI_TERMINAL_ID=<TID>)
            claude --session-id <TID> --settings ~/.lumi/claude-settings.json
        │
   claude ── SessionStart(startup|resume|clear|compact|fork) ──▶ session-start.sh
        │                                                             │ (raw stdin JSON)
        │                                   ~/.lumi/transcript-map/<TID>.json  (atomik overwrite)
        ▼                                                             │
   <transcript_path>.jsonl ◀──── TranscriptWatcher pointer'ı okur ────┘
        │  tail (offset)
        ▼
   RemoteService ── event{transcript} / transcript_reset / snapshot(mirrorable) ──▶ relay ──▶ telefon
```

Tek doğruluk kaynağı: **pointer dosyası** (hook yazar, watcher okur). Watcher tahmin yapmaz.

## 5. Bileşenler

### 5.1 PTY env enjeksiyonu — `LumiTerminal`
Claude spawn'ında process env'ine `LUMI_TERMINAL_ID=<TerminalID.uuidString>` eklenir. cwd zaten
`repoPath`. (`TerminalSession`/`PTYProcess` env geçişi; bugün env özel olarak set edilmiyorsa
eklenecek.) `--session-id <TID>` ve `--settings <lumi-dosyası>` komut kurucuya (`ClaudeSessionID`
/ command builder) eklenir. `LUMI_TERMINAL_ID` = `--session-id` = pointer dosya adı — tek kimlik.

### 5.2 Hook kurulumu — `LumiServices` bootstrap (idempotent)
Uygulama açılışında iki dosya yazılır/güncellenir (varsa üzerine, sürüm damgalı):

- `~/.lumi/hooks/session-start.sh` (jq'suz, `/bin/sh`, atomik):
  ```sh
  #!/bin/sh
  [ -n "$LUMI_TERMINAL_ID" ] || exit 0            # Lumi-dışı oturum → no-op, sessizce çık
  dir="$HOME/.lumi/transcript-map"
  mkdir -p "$dir"
  tmp="$dir/$LUMI_TERMINAL_ID.json.tmp.$$"
  cat > "$tmp"                                     # ham SessionStart JSON'u yaz
  mv -f "$tmp" "$dir/$LUMI_TERMINAL_ID.json"       # atomik rename (yarım okuma yok)
  exit 0
  ```
- `~/.lumi/claude-settings.json` — **yalnız** Lumi'nin SessionStart hook'unu içerir:
  ```json
  { "hooks": { "SessionStart": [ { "hooks": [
      { "type": "command", "command": "sh $HOME/.lumi/hooks/session-start.sh" } ] } ] } }
  ```
  Matcher belirtilmez → tüm kaynaklar (startup/resume/clear/compact/fork) tetikler. claude
  `--settings ~/.lumi/claude-settings.json` ile açıldığından bu hook yalnız Lumi oturumlarında,
  kullanıcının hook'larına **ek** olarak çalışır; kalıcı config'e yazılmaz.

Not: kurumsal `allowManagedHooksOnly: true` politikası hook'u bloklarsa fallback devreye girer
(§5.4). Ayrıca `--settings` ile PTY'den hook'un tetiklendiği gerçek ortamda bir kez doğrulanmalı
(implementasyon doğrulaması).

### 5.3 Pointer store — `~/.lumi/transcript-map/<TID>.json`
İçerik = son SessionStart hook payload'u (ham): `{session_id, transcript_path, cwd, source, ...}`.
TID dosya adında. Atomik overwrite (last-write-wins): `/clear`/`resume` → yeni payload → dosya
güncellenir. Yeni bir `~/.lumi` alt-dizini; mevcut formatlara dokunmaz.

### 5.4 `TranscriptWatcher` yeniden yazımı — `LumiRemote`
`resolveMatch()` yeni sıra (tahminsiz):
1. **Pointer:** `~/.lumi/transcript-map/<TID>.json` oku → `transcript_path`. Dosya diskte
   varsa → o. (Deterministik; normal/worktree/clear/resume/compact hepsini kapsar.)
2. **Fallback exactFile (global):** pointer yoksa (hook henüz tetiklenmedi / kurulu değil /
   politika blokladı) → **tüm** `~/.claude/projects/*/` altında `<TID>.jsonl` ara. id global
   unique olduğundan en çok bir sonuç; worktree'yi hook olmadan da bulur. (İlk oturum için köprü.)
3. Aksi halde → **eşleşme yok** → not-mirrored (§5.5).

Ek davranış:
- **Pointer değişimi (transcript_path farklı):** `matchedFile` değişince offset+pendingPartial
  sıfırlanır (bugünkü poll mantığı) **ve** `/clear`/`resume` demek olduğundan RemoteService'e
  "reset" sinyali verilir → telefon feed'i temizlenip yeni oturum yüklenir (§5.5).
- **Pointer var ama dosya henüz yok** (SessionStart ilk yazımdan önce): eşleşme yok, beklenir —
  hata değil.

**Silinecek:** `TranscriptClaimRegistry.swift` + testleri; `owner`/`registry`/`heuristicMatch`/
`sortedByMtime`/`sessionCreatedAt` mtime mantığı; `RemoteService`'teki `claimRegistry`
register/unregister. `TranscriptWatcher` init'i `terminalID` + `mapDir` alır (repoPath yalnız
fallback global aramada değil, artık gereksiz olabilir — fallback tüm dizinleri tarar).

### 5.5 Protokol + iOS
Mevcut protokole (`docs/spec/50-remote-protocol.md`) iki ekleme:
- **`mirrorable`** — snapshot session nesnesine opsiyonel alan (`awaitingDecision`/`model` gibi):
  yalnız `false` olduğunda bulunur (yoksa → `true`). Watcher §5.4'te "eşleşme yok" sınıfına
  düşen (pointer yok + `<TID>.jsonl` yok) oturum `false`. iOS: chat listede kalır, açılınca
  banner: **"Bu oturum Lumi dışından başlatıldı — transcript yansıtılamıyor."** Giden mesaj
  (`send_text`/`press_key`) açık kalır.
- **`transcript_reset` event** — `{ "kind": "transcript_reset", "sessionId": "<uuid>" }`. Mac,
  bir oturumun aktif dosyası değişince (pointer'da yeni `transcript_path`; `/clear`/`resume`)
  yollar. Telefon davranışı (tek yol): o oturumun feed'ini **temizler**, ardından `get_history`
  ister; sonraki canlı `transcript` item'ları yeni oturumu doldurmaya devam eder. Relay bu
  kind'a bakmaz (push yalnız `status_change`).

## 6. Veri akışı (özet)
claude SessionStart → `session-start.sh` → `~/.lumi/transcript-map/<TID>.json` →
`TranscriptWatcher.poll` pointer okur → dosyayı tail'ler → `FeedItem` → `RemoteService` →
relay → telefon. `/clear` → hook yeni path yazar → watcher dosya değişimini görür → offset
reset + `transcript_reset` → telefon temizlenir, yeni oturum akar.

## 7. Hata yönetimi / zarif düşüş
- Hook kurulu değil / eski claude / `allowManagedHooksOnly` → §5.4-adım2 (global exactFile): ilk
  oturum yansır; `/clear` sonrası yeni dosya bilinemez → o oturum artık eşleşmez → not-mirrored
  bildirimi (sessiz kırılma yerine açık durum). Kırılmaz.
- Kullanıcı Lumi terminaline **elle** `claude` yazarsa (Lumi komut kurmadı → `--session-id` ve
  `--settings` yok): pointer yok, `<TID>.jsonl` yok → not-mirrored. Tutarlı ve dürüst.
- Hook script `/bin/sh`, jq bağımlılığı yok; atomik rename → yarı-yazılmış pointer okunmaz.
- Pointer JSON parse hatası → o poll'da eşleşme yok, sonraki poll tekrar dener.

## 8. Test
Unit (LumiRemote):
- Pointer çözümü: var+dosya var → o dosya; var+dosya yok → nil; pointer bozuk JSON → nil.
- Fallback global exactFile: pointer yok, `<TID>.jsonl` başka proje dizininde (worktree) → bulunur.
- Pointer değişimi: eski→yeni transcript_path → offset reset + `transcript_reset` yayını.
- not-mirrored sınıflandırma: pointer yok + `<TID>.jsonl` hiçbir yerde yok → `mirrorable=false`.
- Registry/heuristic testleri silinir.
Integration:
- Hook simülasyonu: pointer yaz → tail; `/clear` (pointer overwrite, yeni dosya) → dosya
  değişimi + reset; worktree path'i pointer'dan doğru okunur.
Manuel (implementasyon doğrulaması):
- Gerçek cihaz/PTY: `--settings` ile SessionStart hook'un `/clear`'da tetiklendiği + pointer'ın
  yeni path'i yazdığı; telefonun feed'i temizleyip yeni oturuma geçtiği.

## 9. Migrasyon / kaldırma
- `TranscriptClaimRegistry.swift` ve testleri sil.
- `TranscriptWatcher`: pointer + fallback global exactFile'e indir; mtime/registry/sessionCreatedAt kaldır.
- `RemoteService`: claimRegistry ve register/unregister kaldır; watcher'a `terminalID`+map dizini geç;
  pointer-değişimi → `transcript_reset` yayını ekle; snapshot'a `mirrorable` ekle.
- `LumiServices` bootstrap: hook script + `claude-settings.json` idempotent yaz.
- Command builder: `--settings` ekle; PTY env'e `LUMI_TERMINAL_ID` ekle.
- Protokol spec + iOS: `mirrorable` banner + `transcript_reset` işleme.

## 10. Riskler / açık noktalar
- `--settings` hook'unun PTY-spawn'da tetiklenmesi gerçek ortamda doğrulanmalı (belgede engel yok).
- `allowManagedHooksOnly` kurumsal politikası varsa hook devre dışı → fallback (kabul, dokümante).
- Claude JSONL/hook alanları sürüme bağlı (v2.1.169+ doğrulandı); alan adı değişirse pointer parse'ı güncellenmeli.
- `--fork-session` (SessionStart `fork`) da pointer'ı günceller → doğal olarak yeni dosyaya geçer (istenen).
