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
