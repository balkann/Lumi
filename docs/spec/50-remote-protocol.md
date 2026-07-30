# Lumi Remote — Protokol Referansı (v1)

Kaynak tasarım: `docs/superpowers/specs/2026-07-26-lumi-remote-design.md` §6.
Relay implementasyonu: `RelayServer/`.

## Zarf

Tüm mesajlar WebSocket text frame içinde: `{"v":1,"type":"<tip>","payload":{...}}`.
Bilinmeyen tip veya v≠1 → relay bağlantıyı kapatır. `payload` relay için opaktır
(tek istisna: push tetikleme, aşağıda).

İstemciler tablodaki tipler dışında mesaj GÖNDERMEZ — relay bilinmeyen tipte
bağlantıyı kapatır (4002); yeni tip eklemek relay güncellemesi gerektirir.

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
| `snapshot` | mac→relay | Lumi'nin tam durum özeti ([aşağıya bak](#snapshot-payload-macrela-plan-2-tanımı)) | Odada saklanır + telefonlara yayınlanır |
| `event` | mac→relay | `{kind, sessionId, ...}` | Telefonlara yayınlanır; push kuralına bakılır |
| `command` | phone→relay | `{commandId, action, ...}` | Mac'e iletilir; mac yoksa `command_result {ok:false, error:"mac_offline"}` geri döner |
| `command_result` | mac→relay | `{commandId, ok, error?}` | Telefonlara yayınlanır |
| `register_push` | phone→relay | `{deviceToken: string}` | Odaya APNs cihaz token'ı ekler |
| `unregister_push` | phone→relay | `{deviceToken: string}` | Odadan APNs cihaz token'ını siler (toggle kapatma) |
| `ping` / `pong` | her iki yön | `{}` | Uygulama seviyesi canlılık |

Not: Relay'in 30 sn'lik canlılık denetimi transport seviyesinde (WS ping/pong
frame) çalışır; istemcinin uygulama seviyesinde `pong` üretmesi gerekmez —
`ping`/`pong` zarfları isteğe bağlı uygulama-seviyesi denetim içindir.

## Push kuralı

`event.payload.kind == "status_change"` ve `status ∈ {"waiting-unseen","error"}`
ve odada kayıtlı cihaz varsa → APNs alert: title = `repoName` (yoksa "Lumi"),
body = `summary` (yoksa duruma göre genel metin).

## snapshot payload (mac→relay, Plan 2 tanımı)

```json
{
  "sessions": [
    { "id": "<uuid>", "repoPath": "/abs/path", "repoName": "repo",
      "status": "idle|working|waiting-unseen|waiting-focused|waiting-seen|error",
      "title": "<oscTitle, opsiyonel>",
      "awaitingDecision": "<bool, opsiyonel>" }
  ],
  "repos":    [ { "name": "repo", "path": "/abs/path" } ],
  "personas": [ { "id": "reviewer", "label": "Reviewer" } ]
}
```

`title` yalnızca terminalin bir OSC başlığı varsa bulunur.
`awaitingDecision` yalnızca `true` olduğunda bulunur (yoksa → `false`); oturum bir tool izni/kararı bekliyorsa `true`.

### `awaiting_decision`
`{ "kind": "awaiting_decision", "sessionId": "<uuid>", "awaiting": bool }` — Mac bir tool için izin (karar) beklemeye başlayınca `true`, çözülünce `false`. Status'ten ayrı sinyaldir (OSC "needs your permission"); rozet OSC başlığına bağlı olduğundan bu daha güvenilirdir. Relay bu kind'a bakmaz (push kuralı yalnız `status_change`).

## event payload — history (Plan 3.5 backfill)

`{ "kind": "history", "sessionId": "<uuid>", "items": [ {...}, ... ] }` —
`items[]` elemanları transcript `item` şekliyle birebir aynıdır (`itemType` + alanlar),
en çok 50 eleman (jsonl kuyruğunun son ~256KB'ından). Telefon, oturumun akışını bu
listeyle DEĞİŞTİRİR. Relay bu kind'a bakmaz (push kuralı yalnız `status_change`).

## event payload — transcript (mac→relay, Plan 2 tanımı)

`status_change` dışındaki ikinci event türü. `{ "kind": "transcript", "sessionId": "<uuid>", "item": {...} }`; `item.itemType`e göre:

| itemType | ek alanlar |
|---|---|
| `assistant_text` | `text` (string) |
| `tool_use` | `tool` (string), `summary` (string) |
| `question` | `questions`: `[{ "header", "question", "options": ["…"] }]` |
| `turn_done` | (yok) |

## Komut aksiyonları (Plan 2/3 sözleşmesi)

- `send_text {commandId, sessionId, text}`
- `press_key {commandId, sessionId, key}` — key: `"1"|"2"|"3"|"enter"|"esc"`
- `start_session {commandId, repoPath, personaId?, prompt}`
- `get_history {commandId, sessionId}` — oturumun transcript geçmişini ister; Mac önce `event {kind:"history"}` sonra `command_result` döner (Plan 3.5). Hatalar: `session_not_found`, `no_transcript`.
- `delete_session {commandId, sessionId}` — oturumu Mac'te sonlandırır (`terminal.kill`). Ardından `.exited` → yeni `snapshot` yayınlanır ve oturum telefon listesinden düşer. Hata: `session_not_found`.
