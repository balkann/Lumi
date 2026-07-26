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
