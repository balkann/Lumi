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
  'hello', 'welcome', 'sessions', 'repos', 'subscribe', 'unsubscribe',
  'scrollback', 'data', 'chat', 'chat_append', 'input', 'command', 'command_result',
  'register_push', 'unregister_push', 'ping', 'pong',
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
