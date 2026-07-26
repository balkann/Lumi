# Lumi Remote — Plan 1/3: RelayServer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Railway'de koşacak, Mac (Lumi) ile iPhone'u token'la eşleştirip mesaj köprüleyen ve APNs push atan WebSocket relay sunucusu.

**Architecture:** Tek Node.js süreci; tüm durum bellekte. Saf mantık (`protocol`, `registry`, `bridge`, `push`) WebSocket'ten bağımsız modüllerde ve birim testli; `server.ts` yalnızca `ws` kütüphanesini bu mantığa bağlar ve entegrasyon testiyle doğrulanır. Relay, snapshot/event içeriğini **opak** taşır — yalnızca push tetiklemek için `event.kind == "status_change"` alanına bakar.

**Tech Stack:** Node.js 20+, TypeScript (strict, ESM/NodeNext), `ws`, `jose` (APNs JWT), vitest.

**Spec:** `docs/superpowers/specs/2026-07-26-lumi-remote-design.md` (özellikle §4.1, §6, §7, §8)

## Global Constraints

- Node `>=20`; TypeScript `strict: true`; ESM (`"type": "module"`, `module: NodeNext`)
- Runtime bağımlılığı YALNIZ `ws` ve `jose`; başka paket eklenmez
- Tüm durum bellekte — veritabanı, disk, dosya yazımı yok (spec §4.1)
- Mesaj **içeriği** hiçbir log'a yazılmaz (spec §7); yalnız bağlantı/sayı düzeyinde log serbest
- Zarf formatı: `{"v":1,"type":"...","payload":{...}}` — `payload` opak taşınır (spec §6)
- Token en az 16 karakter; geçersiz `hello` bağlantısı sessizce kapatılır (spec §7)
- Kaba kuvvet önlemi: IP başına dakikada 5 başarısız `hello` → sonrakiler direkt kapatılır (spec §7)
- Her task TDD: önce başarısız test, sonra minimal implementasyon
- Çalışma dizini: `/Users/balkan/Lumi/RelayServer/`; commit'ler mevcut `feature/lumi-remote-spec` branch'ine

## File Structure

```
RelayServer/
  package.json            bağımlılıklar + build/start/test script'leri
  tsconfig.json           strict ESM derleme (src → dist)
  src/protocol.ts         zarf parse/validate + hello payload doğrulama
  src/registry.ts         token → Room (mac, phones, snapshot, lastSeenAt, pushTokens)
  src/bridge.ts           mesaj yönlendirme mantığı (ws'den bağımsız) + PushSender arayüzü
  src/push.ts             ApnsPushSender (HTTP/2 + ES256 JWT) ve NoopPushSender
  src/server.ts           ws sunucusu: hello timeout, rate limit, heartbeat
  src/index.ts            entrypoint: env okuma, sunucuyu başlatma
  test/protocol.test.ts
  test/registry.test.ts
  test/bridge.test.ts
  test/server.test.ts     gerçek ws istemcileriyle entegrasyon
docs/spec/50-remote-protocol.md   protokol referansı (Plan 2 ve 3'ün girdisi)
```

---

### Task 1: Proje iskeleti + protocol modülü

**Files:**
- Create: `RelayServer/package.json`
- Create: `RelayServer/tsconfig.json`
- Create: `RelayServer/src/protocol.ts`
- Test: `RelayServer/test/protocol.test.ts`

**Interfaces:**
- Consumes: —
- Produces: `PROTOCOL_VERSION = 1`; `interface Envelope { v: number; type: string; payload: Record<string, unknown> }`; `parseEnvelope(raw: string): Envelope | null`; `envelope(type: string, payload: Record<string, unknown>): string`; `type Role = 'mac' | 'phone'`; `interface HelloPayload { role: Role; token: string }`; `parseHello(p: Record<string, unknown>): HelloPayload | null`

- [ ] **Step 1: İskelet dosyalarını yaz ve bağımlılıkları kur**

`RelayServer/package.json`:

```json
{
  "name": "lumi-relay",
  "private": true,
  "type": "module",
  "engines": { "node": ">=20" },
  "scripts": {
    "build": "tsc",
    "start": "node dist/index.js",
    "test": "vitest run"
  },
  "dependencies": {
    "ws": "^8.18.0",
    "jose": "^5.9.0"
  },
  "devDependencies": {
    "typescript": "^5.6.0",
    "vitest": "^2.1.0",
    "@types/ws": "^8.5.12",
    "@types/node": "^22.5.0"
  }
}
```

`RelayServer/tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "strict": true,
    "outDir": "dist",
    "rootDir": "src",
    "declaration": false,
    "skipLibCheck": true
  },
  "include": ["src"]
}
```

Run: `cd /Users/balkan/Lumi/RelayServer && npm install`
Expected: `added ... packages` — hata yok.

- [ ] **Step 2: Başarısız testi yaz**

`RelayServer/test/protocol.test.ts`:

```ts
import { expect, test } from 'vitest'
import { PROTOCOL_VERSION, envelope, parseEnvelope, parseHello } from '../src/protocol.js'

test('geçerli zarf parse edilir', () => {
  const env = parseEnvelope('{"v":1,"type":"ping","payload":{}}')
  expect(env).toEqual({ v: 1, type: 'ping', payload: {} })
})

test('bozuk JSON, yanlış sürüm, bilinmeyen tip ve eksik payload null döner', () => {
  expect(parseEnvelope('not json')).toBeNull()
  expect(parseEnvelope('{"v":2,"type":"ping","payload":{}}')).toBeNull()
  expect(parseEnvelope('{"v":1,"type":"hack","payload":{}}')).toBeNull()
  expect(parseEnvelope('{"v":1,"type":"ping"}')).toBeNull()
  expect(parseEnvelope('"düz string"')).toBeNull()
})

test('envelope() sürümlü JSON üretir', () => {
  expect(JSON.parse(envelope('pong', { a: 1 }))).toEqual({ v: PROTOCOL_VERSION, type: 'pong', payload: { a: 1 } })
})

test('parseHello rol ve token doğrular', () => {
  expect(parseHello({ role: 'mac', token: 'secret-token-1234567890' }))
    .toEqual({ role: 'mac', token: 'secret-token-1234567890' })
  expect(parseHello({ role: 'phone', token: 'secret-token-1234567890' })?.role).toBe('phone')
  expect(parseHello({ role: 'admin', token: 'secret-token-1234567890' })).toBeNull()
  expect(parseHello({ role: 'mac', token: 'kısa' })).toBeNull()
  expect(parseHello({ role: 'mac' })).toBeNull()
})
```

- [ ] **Step 3: Testin başarısız olduğunu doğrula**

Run: `npx vitest run test/protocol.test.ts`
Expected: FAIL — `Cannot find module '../src/protocol.js'` (ya da benzeri çözümleme hatası).

- [ ] **Step 4: Minimal implementasyonu yaz**

`RelayServer/src/protocol.ts`:

```ts
export const PROTOCOL_VERSION = 1

export type Role = 'mac' | 'phone'

export interface Envelope {
  v: number
  type: string
  payload: Record<string, unknown>
}

export interface HelloPayload {
  role: Role
  token: string
}

const KNOWN_TYPES = new Set([
  'hello', 'welcome', 'snapshot', 'event', 'command', 'command_result',
  'register_push', 'ping', 'pong',
])

const MIN_TOKEN_LENGTH = 16

export function parseEnvelope(raw: string): Envelope | null {
  let data: unknown
  try {
    data = JSON.parse(raw)
  } catch {
    return null
  }
  if (typeof data !== 'object' || data === null || Array.isArray(data)) return null
  const env = data as Record<string, unknown>
  if (env.v !== PROTOCOL_VERSION) return null
  if (typeof env.type !== 'string' || !KNOWN_TYPES.has(env.type)) return null
  if (typeof env.payload !== 'object' || env.payload === null || Array.isArray(env.payload)) return null
  return { v: PROTOCOL_VERSION, type: env.type, payload: env.payload as Record<string, unknown> }
}

export function envelope(type: string, payload: Record<string, unknown>): string {
  return JSON.stringify({ v: PROTOCOL_VERSION, type, payload })
}

export function parseHello(p: Record<string, unknown>): HelloPayload | null {
  if (p.role !== 'mac' && p.role !== 'phone') return null
  if (typeof p.token !== 'string' || p.token.length < MIN_TOKEN_LENGTH) return null
  return { role: p.role, token: p.token }
}
```

- [ ] **Step 5: Testin geçtiğini doğrula**

Run: `npx vitest run test/protocol.test.ts`
Expected: PASS — 4 test yeşil.

- [ ] **Step 6: Commit**

```bash
cd /Users/balkan/Lumi
git add RelayServer/package.json RelayServer/tsconfig.json RelayServer/src/protocol.ts RelayServer/test/protocol.test.ts RelayServer/package-lock.json
git commit -m "relay: proje iskeleti + protokol zarfı parse/validate"
```

---

### Task 2: Registry — token → oda eşleştirme

**Files:**
- Create: `RelayServer/src/registry.ts`
- Test: `RelayServer/test/registry.test.ts`

**Interfaces:**
- Consumes: —
- Produces: `interface ClientLike { send(data: string): void; close(code?: number, reason?: string): void }`; `interface Room { token: string; mac: ClientLike | null; phones: Set<ClientLike>; snapshot: Record<string, unknown> | null; lastSeenAt: number | null; pushTokens: Set<string> }`; `class Registry { constructor(now?: () => number); attachMac(token: string, client: ClientLike): Room; attachPhone(token: string, client: ClientLike): Room; detach(client: ClientLike): void; get(token: string): Room | undefined }`

- [ ] **Step 1: Başarısız testi yaz**

`RelayServer/test/registry.test.ts`:

```ts
import { expect, test } from 'vitest'
import { Registry, type ClientLike } from '../src/registry.js'

function fakeClient(): ClientLike & { closed: boolean } {
  return { closed: false, send() {}, close() { this.closed = true } }
}

const TOKEN = 'secret-token-1234567890'

test('mac ve telefon aynı token ile aynı odada buluşur', () => {
  const reg = new Registry(() => 1000)
  const mac = fakeClient()
  const phone = fakeClient()
  const room1 = reg.attachMac(TOKEN, mac)
  const room2 = reg.attachPhone(TOKEN, phone)
  expect(room1).toBe(room2)
  expect(room1.mac).toBe(mac)
  expect(room1.phones.has(phone)).toBe(true)
  expect(room1.lastSeenAt).toBe(1000)
})

test('ikinci mac bağlanınca eskisi kapatılır', () => {
  const reg = new Registry(() => 1000)
  const eski = fakeClient()
  const yeni = fakeClient()
  reg.attachMac(TOKEN, eski)
  const room = reg.attachMac(TOKEN, yeni)
  expect(eski.closed).toBe(true)
  expect(room.mac).toBe(yeni)
})

test('mac ayrılınca lastSeenAt güncellenir, oda snapshot varsa yaşar', () => {
  let t = 1000
  const reg = new Registry(() => t)
  const mac = fakeClient()
  const room = reg.attachMac(TOKEN, mac)
  room.snapshot = { sessions: [] }
  t = 2000
  reg.detach(mac)
  expect(reg.get(TOKEN)?.mac).toBeNull()
  expect(reg.get(TOKEN)?.lastSeenAt).toBe(2000)
})

test('boş ve snapshot\'sız oda silinir', () => {
  const reg = new Registry(() => 1000)
  const phone = fakeClient()
  reg.attachPhone(TOKEN, phone)
  reg.detach(phone)
  expect(reg.get(TOKEN)).toBeUndefined()
})
```

- [ ] **Step 2: Testin başarısız olduğunu doğrula**

Run: `npx vitest run test/registry.test.ts`
Expected: FAIL — `Cannot find module '../src/registry.js'`.

- [ ] **Step 3: Minimal implementasyonu yaz**

`RelayServer/src/registry.ts`:

```ts
export interface ClientLike {
  send(data: string): void
  close(code?: number, reason?: string): void
}

export interface Room {
  token: string
  mac: ClientLike | null
  phones: Set<ClientLike>
  snapshot: Record<string, unknown> | null
  lastSeenAt: number | null
  pushTokens: Set<string>
}

export class Registry {
  private rooms = new Map<string, Room>()

  constructor(private now: () => number = Date.now) {}

  attachMac(token: string, client: ClientLike): Room {
    const room = this.ensure(token)
    if (room.mac && room.mac !== client) room.mac.close(4000, 'replaced')
    room.mac = client
    room.lastSeenAt = this.now()
    return room
  }

  attachPhone(token: string, client: ClientLike): Room {
    const room = this.ensure(token)
    room.phones.add(client)
    return room
  }

  detach(client: ClientLike): void {
    for (const [token, room] of this.rooms) {
      if (room.mac === client) {
        room.mac = null
        room.lastSeenAt = this.now()
      }
      room.phones.delete(client)
      if (!room.mac && room.phones.size === 0 && !room.snapshot) this.rooms.delete(token)
    }
  }

  get(token: string): Room | undefined {
    return this.rooms.get(token)
  }

  private ensure(token: string): Room {
    let room = this.rooms.get(token)
    if (!room) {
      room = { token, mac: null, phones: new Set(), snapshot: null, lastSeenAt: null, pushTokens: new Set() }
      this.rooms.set(token, room)
    }
    return room
  }
}
```

- [ ] **Step 4: Testin geçtiğini doğrula**

Run: `npx vitest run test/registry.test.ts`
Expected: PASS — 4 test yeşil.

- [ ] **Step 5: Commit**

```bash
cd /Users/balkan/Lumi
git add RelayServer/src/registry.ts RelayServer/test/registry.test.ts
git commit -m "relay: token→oda registry'si"
```

---

### Task 3: Bridge — hello/welcome akışı

**Files:**
- Create: `RelayServer/src/bridge.ts`
- Test: `RelayServer/test/bridge.test.ts`

**Interfaces:**
- Consumes: Task 1 `Envelope`, `envelope`, `parseHello`; Task 2 `Registry`, `ClientLike`, `Room`
- Produces: `interface PushSender { send(deviceTokens: string[], title: string, body: string): Promise<void> }`; `interface Session { client: ClientLike; role: Role; room: Room }`; `class Bridge { constructor(registry: Registry, push: PushSender); handleHello(client: ClientLike, env: Envelope): Session | null; handleMessage(session: Session, env: Envelope): void; handleClose(session: Session): void }`

- [ ] **Step 1: Başarısız testi yaz**

`RelayServer/test/bridge.test.ts` (FakeClient/FakePush yardımcıları sonraki task'lerde de bu dosyada kullanılacak):

```ts
import { expect, test } from 'vitest'
import { Bridge, type PushSender } from '../src/bridge.js'
import { Registry } from '../src/registry.js'
import { parseEnvelope, type Envelope } from '../src/protocol.js'

export class FakeClient {
  sent: Envelope[] = []
  closed = false
  send(data: string) { this.sent.push(parseEnvelope(data)!) }
  close() { this.closed = true }
  last(): Envelope { return this.sent[this.sent.length - 1] }
}

export class FakePush implements PushSender {
  calls: { tokens: string[]; title: string; body: string }[] = []
  async send(tokens: string[], title: string, body: string) {
    this.calls.push({ tokens, title, body })
  }
}

export const TOKEN = 'secret-token-1234567890'

export function env(type: string, payload: Record<string, unknown>): Envelope {
  return { v: 1, type, payload }
}

export function setup() {
  const registry = new Registry(() => 5000)
  const push = new FakePush()
  const bridge = new Bridge(registry, push)
  return { registry, push, bridge }
}

test('geçersiz hello null döner', () => {
  const { bridge } = setup()
  expect(bridge.handleHello(new FakeClient(), env('hello', { role: 'mac', token: 'kısa' }))).toBeNull()
  expect(bridge.handleHello(new FakeClient(), env('ping', {}))).toBeNull()
})

test('telefon hello → welcome içinde snapshot ve macOnline gelir', () => {
  const { bridge } = setup()
  const mac = new FakeClient()
  const macSession = bridge.handleHello(mac, env('hello', { role: 'mac', token: TOKEN }))!
  macSession.room.snapshot = { sessions: [{ id: 's1' }] }

  const phone = new FakeClient()
  bridge.handleHello(phone, env('hello', { role: 'phone', token: TOKEN }))
  expect(phone.last().type).toBe('welcome')
  expect(phone.last().payload).toEqual({
    snapshot: { sessions: [{ id: 's1' }] },
    macOnline: true,
    lastSeenAt: 5000,
  })
})

test('mac hello → welcome içinde phoneCount gelir', () => {
  const { bridge } = setup()
  const mac = new FakeClient()
  bridge.handleHello(mac, env('hello', { role: 'mac', token: TOKEN }))
  expect(mac.last().type).toBe('welcome')
  expect(mac.last().payload).toEqual({ phoneCount: 0 })
})

test('ping → pong', () => {
  const { bridge } = setup()
  const phone = new FakeClient()
  const session = bridge.handleHello(phone, env('hello', { role: 'phone', token: TOKEN }))!
  bridge.handleMessage(session, env('ping', {}))
  expect(phone.last().type).toBe('pong')
})

test('handleClose istemciyi odadan düşürür', () => {
  const { bridge, registry } = setup()
  const mac = new FakeClient()
  const session = bridge.handleHello(mac, env('hello', { role: 'mac', token: TOKEN }))!
  bridge.handleClose(session)
  expect(registry.get(TOKEN)).toBeUndefined()
})
```

- [ ] **Step 2: Testin başarısız olduğunu doğrula**

Run: `npx vitest run test/bridge.test.ts`
Expected: FAIL — `Cannot find module '../src/bridge.js'`.

- [ ] **Step 3: Minimal implementasyonu yaz**

`RelayServer/src/bridge.ts`:

```ts
import { envelope, parseHello, type Envelope, type Role } from './protocol.js'
import { Registry, type ClientLike, type Room } from './registry.js'

export interface PushSender {
  send(deviceTokens: string[], title: string, body: string): Promise<void>
}

export interface Session {
  client: ClientLike
  role: Role
  room: Room
}

export class Bridge {
  constructor(private registry: Registry, private push: PushSender) {}

  handleHello(client: ClientLike, env: Envelope): Session | null {
    if (env.type !== 'hello') return null
    const hello = parseHello(env.payload)
    if (!hello) return null
    const room = hello.role === 'mac'
      ? this.registry.attachMac(hello.token, client)
      : this.registry.attachPhone(hello.token, client)
    if (hello.role === 'phone') {
      client.send(envelope('welcome', {
        snapshot: room.snapshot,
        macOnline: room.mac !== null,
        lastSeenAt: room.lastSeenAt,
      }))
    } else {
      client.send(envelope('welcome', { phoneCount: room.phones.size }))
    }
    return { client, role: hello.role, room }
  }

  handleMessage(session: Session, env: Envelope): void {
    if (env.type === 'ping') {
      session.client.send(envelope('pong', {}))
      return
    }
    // Yönlendirme kuralları Task 4 (mac→telefon) ve Task 5'te (telefon→mac) eklenir.
  }

  handleClose(session: Session): void {
    this.registry.detach(session.client)
  }
}
```

- [ ] **Step 4: Testin geçtiğini doğrula**

Run: `npx vitest run test/bridge.test.ts`
Expected: PASS — 5 test yeşil.

- [ ] **Step 5: Commit**

```bash
cd /Users/balkan/Lumi
git add RelayServer/src/bridge.ts RelayServer/test/bridge.test.ts
git commit -m "relay: bridge hello/welcome akışı"
```

---

### Task 4: Bridge — mac→telefon yönlendirme + push tetikleme

**Files:**
- Modify: `RelayServer/src/bridge.ts` (handleMessage'a mac dalı)
- Test: `RelayServer/test/bridge.test.ts` (dosyadaki `FakeClient`, `FakePush`, `TOKEN`, `env`, `setup` yardımcıları Task 3'ten hazır)

**Interfaces:**
- Consumes: Task 3 `Bridge`, `Session`, `PushSender`; Task 3 test yardımcıları
- Produces: mac'ten gelen `snapshot` / `event` / `command_result` mesajlarının davranışı (aşağıdaki testlerdeki gibi); push tetikleme kuralı: `event.payload.kind === 'status_change'` ve `status ∈ {'waiting-unseen','error'}`

- [ ] **Step 1: Başarısız testleri yaz**

`RelayServer/test/bridge.test.ts` dosyasının sonuna ekle:

```ts
function paired() {
  const s = setup()
  const mac = new FakeClient()
  const phone = new FakeClient()
  const macSession = s.bridge.handleHello(mac, env('hello', { role: 'mac', token: TOKEN }))!
  const phoneSession = s.bridge.handleHello(phone, env('hello', { role: 'phone', token: TOKEN }))!
  return { ...s, mac, phone, macSession, phoneSession }
}

test('snapshot odada saklanır ve telefonlara yayınlanır', () => {
  const { bridge, mac, phone, macSession, registry } = paired()
  bridge.handleMessage(macSession, env('snapshot', { sessions: [{ id: 's1' }] }))
  expect(registry.get(TOKEN)?.snapshot).toEqual({ sessions: [{ id: 's1' }] })
  expect(phone.last().type).toBe('snapshot')
  expect(phone.last().payload).toEqual({ sessions: [{ id: 's1' }] })
  expect(mac.sent.filter((m) => m.type === 'snapshot')).toHaveLength(0)
})

test('event telefonlara yayınlanır; sıradan event push tetiklemez', () => {
  const { bridge, phone, macSession, push } = paired()
  bridge.handleMessage(macSession, env('event', { kind: 'tool_use', sessionId: 's1', summary: 'Bash: swift test' }))
  expect(phone.last().type).toBe('event')
  expect(push.calls).toHaveLength(0)
})

test('waiting-unseen status_change push tetikler (kayıtlı cihaz varsa)', () => {
  const { bridge, macSession, push, registry } = paired()
  registry.get(TOKEN)!.pushTokens.add('device-token-abc')
  bridge.handleMessage(macSession, env('event', {
    kind: 'status_change', sessionId: 's1', status: 'waiting-unseen',
    repoName: 'PowerSlap', summary: 'Bash komutu için izin istiyor',
  }))
  expect(push.calls).toEqual([{
    tokens: ['device-token-abc'], title: 'PowerSlap', body: 'Bash komutu için izin istiyor',
  }])
})

test('working status_change ve cihazsız oda push tetiklemez', () => {
  const { bridge, macSession, push, registry } = paired()
  bridge.handleMessage(macSession, env('event', { kind: 'status_change', sessionId: 's1', status: 'waiting-unseen' }))
  expect(push.calls).toHaveLength(0) // cihaz kayıtlı değil
  registry.get(TOKEN)!.pushTokens.add('device-token-abc')
  bridge.handleMessage(macSession, env('event', { kind: 'status_change', sessionId: 's1', status: 'working' }))
  expect(push.calls).toHaveLength(0) // working push'lanmaz
})

test('command_result telefonlara iletilir', () => {
  const { bridge, phone, macSession } = paired()
  bridge.handleMessage(macSession, env('command_result', { commandId: 'c1', ok: true }))
  expect(phone.last().type).toBe('command_result')
  expect(phone.last().payload).toEqual({ commandId: 'c1', ok: true })
})
```

- [ ] **Step 2: Testlerin başarısız olduğunu doğrula**

Run: `npx vitest run test/bridge.test.ts`
Expected: FAIL — yeni 5 testin tümü (snapshot/event/command_result telefonlara ulaşmıyor).

- [ ] **Step 3: Implementasyonu yaz**

`RelayServer/src/bridge.ts` içinde `handleMessage`'ı güncelle ve özel metotları ekle (Task 3'teki `// Yönlendirme kuralları ...` yorumunun yerine):

```ts
  handleMessage(session: Session, env: Envelope): void {
    if (env.type === 'ping') {
      session.client.send(envelope('pong', {}))
      return
    }
    if (session.role === 'mac') this.fromMac(session, env)
    else this.fromPhone(session, env)
  }

  private fromMac(session: Session, env: Envelope): void {
    const { room } = session
    switch (env.type) {
      case 'snapshot':
        room.snapshot = env.payload
        this.broadcast(room, envelope('snapshot', env.payload))
        break
      case 'event':
        this.broadcast(room, envelope('event', env.payload))
        this.maybePush(room, env.payload)
        break
      case 'command_result':
        this.broadcast(room, envelope('command_result', env.payload))
        break
    }
  }

  private fromPhone(_session: Session, _env: Envelope): void {
    // Telefon→mac komutları Task 5'te eklenir.
  }

  private maybePush(room: Room, p: Record<string, unknown>): void {
    const PUSH_STATUSES = new Set(['waiting-unseen', 'error'])
    if (p.kind !== 'status_change') return
    if (typeof p.status !== 'string' || !PUSH_STATUSES.has(p.status)) return
    if (room.pushTokens.size === 0) return
    const title = typeof p.repoName === 'string' ? p.repoName : 'Lumi'
    const body = typeof p.summary === 'string'
      ? p.summary
      : p.status === 'error' ? 'Oturum hata verdi' : 'Claude cevabını bekliyor'
    void this.push.send([...room.pushTokens], title, body)
  }

  private broadcast(room: Room, data: string): void {
    for (const phone of room.phones) phone.send(data)
  }
```

- [ ] **Step 4: Testlerin geçtiğini doğrula**

Run: `npx vitest run test/bridge.test.ts`
Expected: PASS — 10 test yeşil.

- [ ] **Step 5: Commit**

```bash
cd /Users/balkan/Lumi
git add RelayServer/src/bridge.ts RelayServer/test/bridge.test.ts
git commit -m "relay: mac→telefon yönlendirme ve push tetikleme"
```

---

### Task 5: Bridge — telefon→mac komutları + push kaydı

**Files:**
- Modify: `RelayServer/src/bridge.ts` (`fromPhone` gövdesi)
- Test: `RelayServer/test/bridge.test.ts`

**Interfaces:**
- Consumes: Task 4'teki `paired()` yardımcısı ve `fromPhone` iskeleti
- Produces: telefon `command` → mac'e iletim ya da `command_result {ok:false, error:'mac_offline'}`; `register_push {deviceToken}` → `room.pushTokens`'a ekleme

- [ ] **Step 1: Başarısız testleri yaz**

`RelayServer/test/bridge.test.ts` sonuna ekle:

```ts
test('command mac\'e iletilir', () => {
  const { bridge, mac, phoneSession } = paired()
  bridge.handleMessage(phoneSession, env('command', { commandId: 'c1', action: 'send_text', sessionId: 's1', text: 'devam et' }))
  expect(mac.last().type).toBe('command')
  expect(mac.last().payload).toEqual({ commandId: 'c1', action: 'send_text', sessionId: 's1', text: 'devam et' })
})

test('mac offline iken command anında hata döner', () => {
  const { bridge, mac, phone, macSession, phoneSession } = paired()
  bridge.handleClose(macSession)
  bridge.handleMessage(phoneSession, env('command', { commandId: 'c2', action: 'press_key', sessionId: 's1', key: 'enter' }))
  expect(phone.last().type).toBe('command_result')
  expect(phone.last().payload).toEqual({ commandId: 'c2', ok: false, error: 'mac_offline' })
  expect(mac.sent.filter((m) => m.type === 'command')).toHaveLength(0)
})

test('register_push cihaz token\'ını odaya ekler; geçersizi yok sayar', () => {
  const { bridge, phoneSession, registry } = paired()
  bridge.handleMessage(phoneSession, env('register_push', { deviceToken: 'device-token-abc' }))
  bridge.handleMessage(phoneSession, env('register_push', { deviceToken: '' }))
  bridge.handleMessage(phoneSession, env('register_push', {}))
  expect([...registry.get(TOKEN)!.pushTokens]).toEqual(['device-token-abc'])
})
```

- [ ] **Step 2: Testlerin başarısız olduğunu doğrula**

Run: `npx vitest run test/bridge.test.ts`
Expected: FAIL — yeni 3 test.

- [ ] **Step 3: Implementasyonu yaz**

`RelayServer/src/bridge.ts` içindeki `fromPhone` gövdesini doldur:

```ts
  private fromPhone(session: Session, env: Envelope): void {
    const { room } = session
    switch (env.type) {
      case 'command':
        if (room.mac) {
          room.mac.send(envelope('command', env.payload))
        } else {
          session.client.send(envelope('command_result', {
            commandId: env.payload.commandId ?? null,
            ok: false,
            error: 'mac_offline',
          }))
        }
        break
      case 'register_push':
        if (typeof env.payload.deviceToken === 'string' && env.payload.deviceToken.length > 0) {
          room.pushTokens.add(env.payload.deviceToken)
        }
        break
    }
  }
```

- [ ] **Step 4: Testlerin geçtiğini doğrula**

Run: `npx vitest run test/bridge.test.ts`
Expected: PASS — 13 test yeşil.

- [ ] **Step 5: Commit**

```bash
cd /Users/balkan/Lumi
git add RelayServer/src/bridge.ts RelayServer/test/bridge.test.ts
git commit -m "relay: telefon→mac komutları ve push kaydı"
```

---

### Task 6: APNs push gönderici

**Files:**
- Create: `RelayServer/src/push.ts`
- Test: `RelayServer/test/push.test.ts`

**Interfaces:**
- Consumes: Task 3 `PushSender`
- Produces: `interface ApnsConfig { keyP8: string; keyId: string; teamId: string; bundleId: string; host: string }`; `buildPushBody(title: string, body: string): string`; `class ApnsPushSender implements PushSender` (HTTP/2 POST, 50 dk JWT cache); `class NoopPushSender implements PushSender`

Not: HTTP/2 çağrısının kendisi entegrasyonda gerçek cihazla doğrulanır (spec §11 manuel adım). Birim testleri saf kısımları hedefler: gövde üretimi, JWT üretimi/cache'i, boş listede erken dönüş. Test edilebilirlik için JWT üretimi `mintJwt` olarak dışarı açılır.

- [ ] **Step 1: Başarısız testi yaz**

`RelayServer/test/push.test.ts`:

```ts
import { expect, test } from 'vitest'
import { generateKeyPairSync } from 'node:crypto'
import { buildPushBody, mintJwt, NoopPushSender } from '../src/push.js'

function testKeyP8(): string {
  const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' })
  return privateKey.export({ type: 'pkcs8', format: 'pem' }).toString()
}

test('buildPushBody APNs alert gövdesi üretir', () => {
  expect(JSON.parse(buildPushBody('PowerSlap', 'izin istiyor'))).toEqual({
    aps: { alert: { title: 'PowerSlap', body: 'izin istiyor' }, sound: 'default' },
  })
})

test('mintJwt ES256 başlıklı üç parçalı JWT üretir', async () => {
  const jwt = await mintJwt(testKeyP8(), 'KEYID12345', 'TEAMID1234')
  const [headerB64, payloadB64, sig] = jwt.split('.')
  expect(sig!.length).toBeGreaterThan(0)
  const header = JSON.parse(Buffer.from(headerB64!, 'base64url').toString())
  const payload = JSON.parse(Buffer.from(payloadB64!, 'base64url').toString())
  expect(header).toEqual({ alg: 'ES256', kid: 'KEYID12345' })
  expect(payload.iss).toBe('TEAMID1234')
  expect(typeof payload.iat).toBe('number')
})

test('NoopPushSender sessizce başarır', async () => {
  await expect(new NoopPushSender().send(['t'], 'a', 'b')).resolves.toBeUndefined()
})
```

- [ ] **Step 2: Testin başarısız olduğunu doğrula**

Run: `npx vitest run test/push.test.ts`
Expected: FAIL — `Cannot find module '../src/push.js'`.

- [ ] **Step 3: Implementasyonu yaz**

`RelayServer/src/push.ts`:

```ts
import { connect, type ClientHttp2Session } from 'node:http2'
import { SignJWT, importPKCS8 } from 'jose'
import type { PushSender } from './bridge.js'

export interface ApnsConfig {
  keyP8: string
  keyId: string
  teamId: string
  bundleId: string
  host: string
}

const JWT_TTL_MS = 50 * 60 * 1000

export function buildPushBody(title: string, body: string): string {
  return JSON.stringify({ aps: { alert: { title, body }, sound: 'default' } })
}

export async function mintJwt(keyP8: string, keyId: string, teamId: string): Promise<string> {
  const key = await importPKCS8(keyP8, 'ES256')
  return new SignJWT({})
    .setProtectedHeader({ alg: 'ES256', kid: keyId })
    .setIssuer(teamId)
    .setIssuedAt()
    .sign(key)
}

export class ApnsPushSender implements PushSender {
  private jwt: { value: string; issuedAt: number } | null = null

  constructor(private cfg: ApnsConfig) {}

  async send(deviceTokens: string[], title: string, body: string): Promise<void> {
    if (deviceTokens.length === 0) return
    const jwt = await this.token()
    const session = connect(this.cfg.host)
    try {
      await Promise.all(deviceTokens.map((t) => this.post(session, jwt, t, title, body)))
    } finally {
      session.close()
    }
  }

  private async token(): Promise<string> {
    const now = Date.now()
    if (this.jwt && now - this.jwt.issuedAt < JWT_TTL_MS) return this.jwt.value
    const value = await mintJwt(this.cfg.keyP8, this.cfg.keyId, this.cfg.teamId)
    this.jwt = { value, issuedAt: now }
    return value
  }

  private post(session: ClientHttp2Session, jwt: string, deviceToken: string, title: string, body: string): Promise<void> {
    return new Promise((resolve) => {
      const req = session.request({
        ':method': 'POST',
        ':path': `/3/device/${deviceToken}`,
        authorization: `bearer ${jwt}`,
        'apns-topic': this.cfg.bundleId,
        'apns-push-type': 'alert',
        'apns-priority': '10',
      })
      // İçerik loglanmaz (spec §7); push hatası akışı bozmaz, sessizce geçilir.
      req.on('response', (headers) => {
        const status = headers[':status']
        if (status !== 200) console.warn(`apns: status ${status}`)
      })
      req.on('close', () => resolve())
      req.on('error', () => resolve())
      req.end(buildPushBody(title, body))
    })
  }
}

export class NoopPushSender implements PushSender {
  async send(): Promise<void> {}
}
```

- [ ] **Step 4: Testin geçtiğini doğrula**

Run: `npx vitest run test/push.test.ts`
Expected: PASS — 3 test yeşil.

- [ ] **Step 5: Commit**

```bash
cd /Users/balkan/Lumi
git add RelayServer/src/push.ts RelayServer/test/push.test.ts
git commit -m "relay: APNs push gönderici (JWT cache + noop varyantı)"
```

---

### Task 7: server.ts — ws bağlama, hello timeout, rate limit, heartbeat

**Files:**
- Create: `RelayServer/src/server.ts`
- Test: `RelayServer/test/server.test.ts`

**Interfaces:**
- Consumes: Task 1 `parseEnvelope`; Task 2 `Registry`; Task 3 `Bridge`, `Session`, `PushSender`; Task 6 `NoopPushSender` (testte)
- Produces: `interface ServerOptions { port: number; push: PushSender; helloTimeoutMs?: number; heartbeatMs?: number }`; `startServer(opts: ServerOptions): { wss: WebSocketServer; close(): void }` — `port: 0` verilirse OS rastgele port atar (test için)

- [ ] **Step 1: Başarısız entegrasyon testini yaz**

`RelayServer/test/server.test.ts`:

```ts
import { afterEach, expect, test } from 'vitest'
import WebSocket from 'ws'
import { startServer } from '../src/server.js'
import { NoopPushSender } from '../src/push.js'

const TOKEN = 'secret-token-1234567890'
let server: ReturnType<typeof startServer> | null = null

afterEach(() => { server?.close(); server = null })

function serverPort(): number {
  const addr = server!.wss.address()
  if (typeof addr === 'object' && addr) return addr.port
  throw new Error('port alınamadı')
}

function connect(): Promise<WebSocket> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${serverPort()}`)
    ws.on('open', () => resolve(ws))
    ws.on('error', reject)
  })
}

function nextMessage(ws: WebSocket): Promise<{ v: number; type: string; payload: Record<string, unknown> }> {
  return new Promise((resolve) => ws.once('message', (d) => resolve(JSON.parse(d.toString()))))
}

function closed(ws: WebSocket): Promise<void> {
  return new Promise((resolve) => ws.once('close', () => resolve()))
}

function send(ws: WebSocket, type: string, payload: Record<string, unknown>): void {
  ws.send(JSON.stringify({ v: 1, type, payload }))
}

test('mac ve telefon eşleşir; snapshot ve command çift yönlü akar', async () => {
  server = startServer({ port: 0, push: new NoopPushSender() })
  const mac = await connect()
  send(mac, 'hello', { role: 'mac', token: TOKEN })
  expect((await nextMessage(mac)).type).toBe('welcome')

  const phone = await connect()
  send(phone, 'hello', { role: 'phone', token: TOKEN })
  const welcome = await nextMessage(phone)
  expect(welcome.payload.macOnline).toBe(true)

  send(mac, 'snapshot', { sessions: [{ id: 's1' }] })
  const snap = await nextMessage(phone)
  expect(snap.type).toBe('snapshot')

  send(phone, 'command', { commandId: 'c1', action: 'send_text', sessionId: 's1', text: 'merhaba' })
  const cmd = await nextMessage(mac)
  expect(cmd.type).toBe('command')
  expect(cmd.payload.text).toBe('merhaba')
})

test('geçersiz ilk mesaj bağlantıyı kapatır', async () => {
  server = startServer({ port: 0, push: new NoopPushSender() })
  const ws = await connect()
  send(ws, 'hello', { role: 'mac', token: 'kısa' })
  await closed(ws)
})

test('hello gelmezse timeout ile kapanır', async () => {
  server = startServer({ port: 0, push: new NoopPushSender(), helloTimeoutMs: 50 })
  const ws = await connect()
  await closed(ws)
})

test('aynı IP 5 başarısız hello sonrası reddedilir', async () => {
  server = startServer({ port: 0, push: new NoopPushSender() })
  for (let i = 0; i < 5; i++) {
    const ws = await connect()
    send(ws, 'hello', { role: 'mac', token: 'kısa' })
    await closed(ws)
  }
  const ws = await connect()
  send(ws, 'hello', { role: 'mac', token: TOKEN }) // geçerli token bile olsa
  await closed(ws)
})
```

- [ ] **Step 2: Testin başarısız olduğunu doğrula**

Run: `npx vitest run test/server.test.ts`
Expected: FAIL — `Cannot find module '../src/server.js'`.

- [ ] **Step 3: Implementasyonu yaz**

`RelayServer/src/server.ts`:

```ts
import { WebSocketServer, WebSocket } from 'ws'
import { Bridge, type PushSender, type Session } from './bridge.js'
import { Registry } from './registry.js'
import { parseEnvelope } from './protocol.js'

export interface ServerOptions {
  port: number
  push: PushSender
  helloTimeoutMs?: number
  heartbeatMs?: number
}

const MAX_FAILED_HELLOS = 5
const FAILURE_WINDOW_MS = 60_000

export function startServer(opts: ServerOptions): { wss: WebSocketServer; close(): void } {
  const registry = new Registry()
  const bridge = new Bridge(registry, opts.push)
  const wss = new WebSocketServer({ port: opts.port })
  const failedHellos = new Map<string, { count: number; resetAt: number }>()

  wss.on('connection', (ws: WebSocket & { isAlive?: boolean }, req) => {
    const ip = req.socket.remoteAddress ?? 'unknown'
    const client = {
      send: (d: string) => { if (ws.readyState === WebSocket.OPEN) ws.send(d) },
      close: (c?: number, r?: string) => ws.close(c, r),
    }
    let session: Session | null = null
    ws.isAlive = true

    const helloTimer = setTimeout(() => {
      if (!session) ws.close(4001, 'hello timeout')
    }, opts.helloTimeoutMs ?? 5000)

    ws.on('pong', () => { ws.isAlive = true })
    ws.on('message', (data) => {
      const env = parseEnvelope(data.toString())
      if (!env) { ws.close(4002, 'bad message'); return }
      if (!session) {
        if (tooManyFailures(ip)) { ws.close(); return }
        session = bridge.handleHello(client, env)
        if (session) clearTimeout(helloTimer)
        else { recordFailure(ip); ws.close() }
        return
      }
      bridge.handleMessage(session, env)
    })
    ws.on('close', () => {
      clearTimeout(helloTimer)
      if (session) bridge.handleClose(session)
    })
  })

  const heartbeat = setInterval(() => {
    for (const ws of wss.clients as Set<WebSocket & { isAlive?: boolean }>) {
      if (ws.isAlive === false) { ws.terminate(); continue }
      ws.isAlive = false
      ws.ping()
    }
  }, opts.heartbeatMs ?? 30_000)

  function tooManyFailures(ip: string): boolean {
    const entry = failedHellos.get(ip)
    return !!entry && entry.resetAt > Date.now() && entry.count >= MAX_FAILED_HELLOS
  }

  function recordFailure(ip: string): void {
    const now = Date.now()
    const entry = failedHellos.get(ip)
    if (!entry || entry.resetAt < now) failedHellos.set(ip, { count: 1, resetAt: now + FAILURE_WINDOW_MS })
    else entry.count += 1
  }

  return {
    wss,
    close: () => {
      clearInterval(heartbeat)
      for (const ws of wss.clients) ws.terminate()
      wss.close()
    },
  }
}
```

- [ ] **Step 4: Testin geçtiğini doğrula**

Run: `npx vitest run test/server.test.ts`
Expected: PASS — 4 test yeşil.

Sonra tüm paket: `npm test`
Expected: PASS — 4 dosya, 24 test yeşil.

- [ ] **Step 5: Commit**

```bash
cd /Users/balkan/Lumi
git add RelayServer/src/server.ts RelayServer/test/server.test.ts
git commit -m "relay: ws sunucusu — hello timeout, rate limit, heartbeat"
```

---

### Task 8: Entrypoint, protokol referans dokümanı, Railway deploy

**Files:**
- Create: `RelayServer/src/index.ts`
- Create: `docs/spec/50-remote-protocol.md`
- Modify: `RelayServer/package.json` (değişiklik yok — doğrulama adımı `npm run build`)

**Interfaces:**
- Consumes: Task 6 `ApnsPushSender`, `NoopPushSender`; Task 7 `startServer`
- Produces: `node dist/index.js` ile çalışan sunucu; env değişkenleri: `PORT` (Railway otomatik verir), opsiyonel `APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`, `APNS_HOST`; Plan 2/3'ün referans alacağı protokol dokümanı

- [ ] **Step 1: Entrypoint'i yaz**

`RelayServer/src/index.ts`:

```ts
import { startServer } from './server.js'
import { ApnsPushSender, NoopPushSender } from './push.js'

const port = Number(process.env.PORT ?? 8080)
const { APNS_KEY_P8, APNS_KEY_ID, APNS_TEAM_ID, APNS_BUNDLE_ID, APNS_HOST } = process.env

const push = APNS_KEY_P8 && APNS_KEY_ID && APNS_TEAM_ID && APNS_BUNDLE_ID
  ? new ApnsPushSender({
      keyP8: APNS_KEY_P8.replace(/\\n/g, '\n'),
      keyId: APNS_KEY_ID,
      teamId: APNS_TEAM_ID,
      bundleId: APNS_BUNDLE_ID,
      host: APNS_HOST ?? 'https://api.push.apple.com',
    })
  : new NoopPushSender()

startServer({ port, push })
console.log(`lumi-relay :${port} dinliyor (push: ${push instanceof NoopPushSender ? 'kapalı' : 'APNs'})`)
```

- [ ] **Step 2: Build'in temiz geçtiğini doğrula**

Run: `cd /Users/balkan/Lumi/RelayServer && npm run build && node dist/index.js &` sonra `sleep 1 && kill %1`
Expected: derleme hatasız; stdout'ta `lumi-relay :8080 dinliyor (push: kapalı)`.

- [ ] **Step 3: Protokol referans dokümanını yaz**

`docs/spec/50-remote-protocol.md` — Plan 2 (LumiRemote) ve Plan 3 (iOS) bu dosyayı bağlayıcı referans alır:

```markdown
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
```

- [ ] **Step 4: Testlerin hâlâ geçtiğini doğrula ve commit'le**

Run: `cd /Users/balkan/Lumi/RelayServer && npm test`
Expected: PASS — 24 test yeşil.

```bash
cd /Users/balkan/Lumi
git add RelayServer/src/index.ts docs/spec/50-remote-protocol.md
git commit -m "relay: entrypoint + protokol referans dokümanı"
```

- [ ] **Step 5: Railway'e deploy (manuel — kullanıcı hesabı gerektirir)**

Kullanıcıyla birlikte yürütülecek adımlar (Railway CLI: `npm i -g @railway/cli`):

```bash
cd /Users/balkan/Lumi/RelayServer
railway login          # tarayıcı açılır, kullanıcı girişi
railway init           # yeni proje: "lumi-relay"
railway up             # build + deploy (npm run build && npm start)
railway domain         # wss:// için public domain üret
```

Smoke test (domain'i yerine koyarak):

```bash
npx wscat -c wss://<domain>
> {"v":1,"type":"hello","payload":{"role":"phone","token":"secret-token-1234567890"}}
```

Expected: `{"v":1,"type":"welcome","payload":{"snapshot":null,"macOnline":false,"lastSeenAt":null}}`

APNs env değişkenleri (Plan 3'te Apple Developer hesabı hazır olunca): Railway
dashboard → Variables → `APNS_KEY_P8` (.p8 içeriği), `APNS_KEY_ID`, `APNS_TEAM_ID`,
`APNS_BUNDLE_ID`. O güne kadar push `NoopPushSender` ile kapalı — tasarım gereği.

---

## Self-Review Kaydı

- **Spec kapsaması:** §4.1 (köprüleme, bellek-içi snapshot, push) → Task 2–6; §6 (zarf, mesajlar, komutlar) → Task 1, 4, 5 + referans doc; §7 (token, sessiz kapatma, rate limit, içerik loglamama) → Task 1, 7 + push.ts yorumu; §8 (APNs) → Task 6, 8; §9 (mac_offline, relay restart) → Task 5, 7 (restart senaryosu: bellek-içi durum kaybolur, mac yeniden bağlanınca snapshot tazelenir — ek kod gerektirmez). E2E zarf ayrıklığı → payload opak taşınıyor.
- **Placeholder taraması:** temiz; Task 3'teki "sonraki task'te eklenir" yorumları planın kendi içinde tanımlı (Task 4/5 kodu mevcut).
- **Tip tutarlılığı:** `ClientLike`/`Room`/`Session`/`PushSender` imzaları task'ler arasında birebir aynı; test yardımcıları (`paired`, `FakeClient`) tek dosyada yaşıyor.

## Sonraki planlar

- **Plan 2/3 — LumiRemote (Mac modülü):** `RelayConnection`, `SnapshotBuilder`, `TranscriptWatcher`, `RemoteCommandHandler`; `docs/spec/50-remote-protocol.md`'yi sözleşme alır. Plan 1 bittikten sonra yazılacak.
- **Plan 3/3 — LumiMobile (iOS):** SwiftUI istemci + APNs. Plan 2 bittikten sonra yazılacak.
