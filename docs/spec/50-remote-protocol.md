# Lumi Remote — Protokol Referansı (v1)

Kaynak tasarım: `docs/superpowers/specs/2026-07-26-lumi-remote-design.md` §6.
Relay implementasyonu: `RelayServer/`.

## Zarf

Tüm mesajlar WebSocket text frame içinde: `{"v":1,"type":"<tip>","payload":{...}}`.
Bilinmeyen tip veya v≠1 → relay bağlantıyı kapatır. `payload` relay için opaktır
(tek istisna: push tetikleme, aşağıda).

## Bağlantı açılışı

İlk mesaj `hello` olmalı (5 sn içinde, yoksa kapanır):
`{role: "mac"|"phone", token: string≥16}`.
Cevap `welcome` — telefona: `{snapshot: object|null, macOnline: bool, lastSeenAt: number|null}`;
mac'e: `{phoneCount: number}`.
Geçersiz hello sessizce kapatılır; IP başına dakikada 5 başarısız denemeden
sonra yeni denemeler direkt kapatılır.

## Mesaj tablosu

| Tip | Yön | Payload | Davranış |
|---|---|---|---|
| `snapshot` | mac→relay | Lumi'nin tam durum özeti (Plan 2 tanımlar) | Odada saklanır + telefonlara yayınlanır |
| `event` | mac→relay | `{kind, sessionId, ...}` | Telefonlara yayınlanır; push kuralına bakılır |
| `command` | phone→relay | `{commandId, action, ...}` | Mac'e iletilir; mac yoksa `command_result {ok:false, error:"mac_offline"}` geri döner |
| `command_result` | mac→relay | `{commandId, ok, error?}` | Telefonlara yayınlanır |
| `register_push` | phone→relay | `{deviceToken: string}` | Odaya APNs cihaz token'ı ekler |
| `ping` / `pong` | her iki yön | `{}` | Uygulama seviyesi canlılık |

## Push kuralı

`event.payload.kind == "status_change"` ve `status ∈ {"waiting-unseen","error"}`
ve odada kayıtlı cihaz varsa → APNs alert: title = `repoName` (yoksa "Lumi"),
body = `summary` (yoksa duruma göre genel metin).

## Komut aksiyonları (Plan 2/3 sözleşmesi)

- `send_text {commandId, sessionId, text}`
- `press_key {commandId, sessionId, key}` — key: `"1"|"2"|"3"|"enter"|"esc"`
- `start_session {commandId, repoPath, personaId?, prompt}`
