# Faz 4 — Composer Paritesi (Remote Native Chat)

**Tarih:** 2026-09-16
**Branch:** `feat/remote-orca-main` (main'e commit YOK)
**Durum:** DEVİR TASLAĞI — implementasyondan önce `superpowers:brainstorming` + yoğun orca keşfi. Bu faz büyük ve çok-özellikli; **alt-fazlara bölünmesi önerilir** (her biri kendi spec→plan→SDD döngüsü).
**Referans: orca** (`/Users/balkan/Desktop/side-projects/orca`), `mobile/` dizini.

## 1. Amaç ve kapsam

Telefon chat composer'ını orca mobil composer paritesine getirir. Faz 1'in basit
TextField+Gönder'inin üstüne, orca'nın giriş özelliklerini ekler:

- **@-dosya autocomplete** (repo dosya adı tamamlama).
- **Slash komut** menüsü (`/clear`, `/model`, … Claude slash komutları).
- **Model / session picker** (aktif oturumun modelini değiştir, oturum seç).
- **Görsel ekleme** (fotoğraf/pano → `image-ref`; Faz 1 decode+stub hazır, render burada).
- **Diktasyon** (ses→metin; cihaz mikrofon TCC).
- **Optimistic echo** (gönderilen mesaj anında görünür, ack'te sabitlenir).
- **Pagination** (uzun transcript'te geriye kaydırma / sayfalama).
- **Pinch-zoom** (mesaj alanı font ölçeği).

### Kapsam dışı (bilinçli)
- Yeni sağlayıcı (Codex Faz 5).
- Reasoning/subagent/diff render (Faz 5).

### ÖNERİLEN ALT-FAZ BÖLÜMÜ (devralan karar versin)
- **Faz 4.0:** @-dosya + slash + model/session picker (metin-giriş yardımcıları).
- **Faz 4.1:** görsel ekleme + `image-ref` render + diktasyon (medya/TCC).
- **Faz 4.2:** optimistic echo + pagination + pinch-zoom (görüntüleme/performans).

## 2. Mevcut zemin (yeniden kullanılan)
- **Faz 1 composer** (`LumiMobile/App/MobileChatView.swift` — `composer`, `submitText`).
- **`ChatMessage`/`ChatBlock`** (`image-ref` bloğu Faz 1'de decode+stub — render Faz 4.1).
- **`command`/`command_result` frame'leri** (model değiştirme/slash için mevcut komut kanalı).
- **`sendInput`/`submitText`** (metin gönderim yolu, Faz 2 send-submit fix).
- **`RemoteCommandHandler`** (Mac tarafı komut uygulama).

## 3. Mimari yön (devralan netleştirir)
- **@-dosya:** repo dosya listesi Mac'ten telefona (yeni `repo_files` frame veya `command`);
  telefonda inline autocomplete popover. Mac tarafı file-tree tarama (mevcut Explorer altyapısı).
- **Slash:** Claude slash komutları listesi statik/dinamik; seçim `submitText` ile PTY'ye.
- **Model/session picker:** mevcut `command` (set_model) + `sessions` frame.
- **Görsel:** telefon fotoğraf → base64/attachment → yeni `attachment`/image frame → Mac
  claude'a iletir (orca'nın attachment akışı); `image-ref` render mobil `ChatBlock`.
- **Diktasyon:** iOS `Speech` framework (mikrofon TCC — mevcut voice-mode TCC zinciri notu).
- **Optimistic echo/pagination/pinch:** saf telefon-tarafı UI (AppModel + MobileChatView).

## 4. Test stratejisi
- Metin-giriş yardımcıları: AppModel/protocol birim testleri (@-dosya filtre, slash parse).
- Görsel/attachment wire: RemoteService + relay passthrough + PhoneProtocol decode.
- UI (autocomplete popover, picker, pinch, diktasyon) = cihaz.

## 5. Referans orca dosyaları (devralan keşfetsin — bu spec bunları DERİN incelemedi)
- `mobile/src/` composer/input bileşenleri (autocomplete, slash, model picker, attachment).
- `mobile/src/session/` attachment/görsel gönderim akışı; diktasyon.
- `src/renderer/src/components/native-chat/` composer paralel (desktop referans).
- `src/shared/agent-session-*.ts` (attachment/journal tipleri).

## 6. Önce yap (implementasyondan önce — ZORUNLU)
1. **orca `mobile/` composer'ını derinlemesine keşfet** (bu spec yalnız Faz 1 roadmap'inden
   yön verdi; her alt-özellik için orca akışını çıkar).
2. **Alt-fazlara böl** (yukarıdaki 4.0/4.1/4.2 önerisi) — tek spec çok büyük.
3. Her alt-faz için `superpowers:brainstorming` → `writing-plans` → SDD.
