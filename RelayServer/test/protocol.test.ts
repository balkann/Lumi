import { expect, test, describe, it } from 'vitest'
import { PROTOCOL_VERSION, envelope, parseEnvelope, parseHello } from '../src/protocol.js'

test('geçerli zarf parse edilir', () => {
  const env = parseEnvelope('{"v":1,"type":"ping","payload":{}}')
  expect(env).toEqual({ v: 1, type: 'ping', payload: {} })
})

test('bozuk JSON, yanlış sürüm ve eksik payload null döner', () => {
  expect(parseEnvelope('not json')).toBeNull()
  expect(parseEnvelope('{"v":2,"type":"ping","payload":{}}')).toBeNull()
  expect(parseEnvelope('{"v":1,"type":"ping"}')).toBeNull()
  expect(parseEnvelope('"düz string"')).toBeNull()
})

// İleri-uyum: relay eski kalsa bile yeni frame tipi BAĞLANTIYI ÖLDÜRMEZ.
// (Bayat-deploy faciası: eski relay chat_status/prompt'u tanımayıp mac'i 4002 ile
// düşürüyordu → telefon kartları hiç alamıyordu.) Şekil-geçerli bilinmeyen tip
// parse edilir; bridge onu no-op yok sayar.
test('bilinmeyen ama şekil-geçerli tip parse edilir (bağlantı kapanmaz)', () => {
  expect(parseEnvelope('{"v":1,"type":"future_feature","payload":{"x":1}}'))
    .toEqual({ v: 1, type: 'future_feature', payload: { x: 1 } })
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
  it('tanınmayan tipler de parse edilir (bridge no-op yok sayar, kapatmaz)', () => {
    for (const type of ['snapshot', 'event']) {
      const raw = JSON.stringify({ v: 1, type, payload: {} })
      expect(parseEnvelope(raw)?.type).toBe(type)
    }
  })
})
