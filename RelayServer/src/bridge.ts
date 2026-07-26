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
