import { expect, test } from 'vitest'
import { generateKeyPairSync } from 'node:crypto'
import { buildPushBody, mintJwt, NoopPushSender } from '../src/push.js'

function testKeyP8(): string {
  const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' })
  return privateKey.export({ type: 'pkcs8', format: 'pem' }).toString()
}

test('buildPushBody APNs alert gövdesi üretir', () => {
  expect(JSON.parse(buildPushBody('PowerSlap', 'izin istiyor'))).toEqual({
    aps: { alert: { title: 'PowerSlap', body: 'izin istiyor' }, sound: 'default' },
  })
})

test('mintJwt ES256 başlıklı üç parçalı JWT üretir', async () => {
  const jwt = await mintJwt(testKeyP8(), 'KEYID12345', 'TEAMID1234')
  const [headerB64, payloadB64, sig] = jwt.split('.')
  expect(sig!.length).toBeGreaterThan(0)
  const header = JSON.parse(Buffer.from(headerB64!, 'base64url').toString())
  const payload = JSON.parse(Buffer.from(payloadB64!, 'base64url').toString())
  expect(header).toEqual({ alg: 'ES256', kid: 'KEYID12345' })
  expect(payload.iss).toBe('TEAMID1234')
  expect(typeof payload.iat).toBe('number')
})

test('NoopPushSender sessizce başarır', async () => {
  await expect(new NoopPushSender().send(['t'], 'a', 'b')).resolves.toBeUndefined()
})
