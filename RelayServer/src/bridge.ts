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
      case 'unregister_push':
        if (typeof env.payload.deviceToken === 'string' && env.payload.deviceToken.length > 0) {
          room.pushTokens.delete(env.payload.deviceToken)
        }
        break
    }
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
    this.push.send([...room.pushTokens], title, body).catch((err) => {
      console.error('push gönderimi başarısız:', err instanceof Error ? err.message : err)
    })
  }

  private broadcast(room: Room, data: string): void {
    for (const phone of room.phones) phone.send(data)
  }

  handleClose(session: Session): void {
    this.registry.detach(session.client)
  }
}
