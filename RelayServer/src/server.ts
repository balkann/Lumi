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
