import { expect, test, describe, it } from 'vitest'
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

describe('terminal-stream protocol', () => {
  it('accepts new terminal-stream types', () => {
    for (const type of ['sessions', 'subscribe', 'unsubscribe', 'scrollback', 'data', 'input']) {
      const raw = JSON.stringify({ v: 1, type, payload: {} })
      expect(parseEnvelope(raw)?.type).toBe(type)
    }
  })
  it('rejects removed chat types', () => {
    for (const type of ['snapshot', 'event']) {
      const raw = JSON.stringify({ v: 1, type, payload: {} })
      expect(parseEnvelope(raw)).toBeNull()
    }
  })
})
