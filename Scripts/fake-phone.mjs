// Kullanım: node Scripts/fake-phone.mjs <token> [relay-url]
// Telefon rolüyle relay'e bağlanır; welcome+snapshot'ı basar, event'leri dinler.
// stdin komutları:
//   send <sessionId> <metin>          → send_text
//   key <sessionId> <1|2|3|enter|esc> → press_key
//   start <repoPath> <prompt...>      → start_session
import WebSocket from '../RelayServer/node_modules/ws/wrapper.mjs'
import readline from 'node:readline'

const token = process.argv[2]
const url = process.argv[3] ?? 'wss://lumi-relay-production.up.railway.app'
if (!token) { console.error('kullanım: node fake-phone.mjs <token> [relay-url]'); process.exit(1) }

const ws = new WebSocket(url)
const send = (type, payload) => ws.send(JSON.stringify({ v: 1, type, payload }))

ws.on('open', () => send('hello', { role: 'phone', token }))
ws.on('message', (d) => {
  const env = JSON.parse(d.toString())
  console.log(`\n[${env.type}]`, JSON.stringify(env.payload, null, 1).slice(0, 1200))
})
ws.on('close', () => { console.log('bağlantı kapandı'); process.exit(0) })
ws.on('error', (e) => { console.error('hata:', e.message); process.exit(1) })

const rl = readline.createInterface({ input: process.stdin })
let n = 0
rl.on('line', (line) => {
  let m
  if ((m = line.match(/^send (\S+) (.+)$/)))
    send('command', { commandId: `fp-${++n}`, action: 'send_text', sessionId: m[1], text: m[2] })
  else if ((m = line.match(/^key (\S+) (\S+)$/)))
    send('command', { commandId: `fp-${++n}`, action: 'press_key', sessionId: m[1], key: m[2] })
  else if ((m = line.match(/^start (\S+) ?(.*)$/)))
    send('command', { commandId: `fp-${++n}`, action: 'start_session', repoPath: m[1], prompt: m[2] ?? '' })
})
