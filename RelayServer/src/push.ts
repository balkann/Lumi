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
    let jwt: string
    try {
      jwt = await this.token()
    } catch (err) {
      console.warn('apns: jwt üretilemedi:', err instanceof Error ? err.message : err)
      return
    }
    const session = connect(this.cfg.host)
    session.on('error', (err) => {
      console.warn('apns: bağlantı hatası:', err instanceof Error ? err.message : err)
    })
    session.setTimeout(10_000, () => session.destroy())
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
        'content-type': 'application/json',
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
