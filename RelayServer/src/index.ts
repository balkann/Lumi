import { startServer } from './server.js'
import { ApnsPushSender, NoopPushSender } from './push.js'

const port = Number(process.env.PORT ?? 8080)
const { APNS_KEY_P8, APNS_KEY_ID, APNS_TEAM_ID, APNS_BUNDLE_ID, APNS_HOST } = process.env

const push = APNS_KEY_P8 && APNS_KEY_ID && APNS_TEAM_ID && APNS_BUNDLE_ID
  ? new ApnsPushSender({
      keyP8: APNS_KEY_P8.replace(/\\n/g, '\n'),
      keyId: APNS_KEY_ID,
      teamId: APNS_TEAM_ID,
      bundleId: APNS_BUNDLE_ID,
      host: APNS_HOST ?? 'https://api.push.apple.com',
    })
  : new NoopPushSender()

startServer({ port, push })
console.log(`lumi-relay :${port} dinliyor (push: ${push instanceof NoopPushSender ? 'kapalı' : 'APNs'})`)
