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

test('mac ayrılınca lastSeenAt güncellenir, oda sessions varsa yaşar', () => {
  let t = 1000
  const reg = new Registry(() => t)
  const mac = fakeClient()
  const room = reg.attachMac(TOKEN, mac)
  room.sessions = []
  t = 2000
  reg.detach(mac)
  expect(reg.get(TOKEN)?.mac).toBeNull()
  expect(reg.get(TOKEN)?.lastSeenAt).toBe(2000)
})

test('boş ve sessions\'sız oda silinir', () => {
  const reg = new Registry(() => 1000)
  const phone = fakeClient()
  reg.attachPhone(TOKEN, phone)
  reg.detach(phone)
  expect(reg.get(TOKEN)).toBeUndefined()
})
