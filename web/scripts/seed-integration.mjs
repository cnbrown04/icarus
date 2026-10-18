// Seeds a running icarus-server for the real-server Playwright suite (playwright.integration.config.ts).
// Run once after `icarus-server create-user` with the same password.
//
// Environment:
//   ICARUS_BASE_URL      default http://localhost:8080
//   ICARUS_E2E_EMAIL     default e2e@example.com (the user created with create-user)
//   ICARUS_E2E_PASSWORD  required, that user's password
//   ICARUS_E2E_DIR       default <tmpdir>/icarus-e2e
//
// Writes two files, mode 0600, into ICARUS_E2E_DIR:
//   storage.json  a Playwright storage state holding a web session cookie
//   seed.json     the paired phone, whose token the sync checks use
// Only counts are printed. Health values and tokens never reach the log.

import { randomBytes } from 'node:crypto'
import { mkdirSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const BASE_URL = (process.env.ICARUS_BASE_URL ?? 'http://localhost:8080').replace(/\/$/, '')
const EMAIL = process.env.ICARUS_E2E_EMAIL ?? 'e2e@example.com'
const PASSWORD = process.env.ICARUS_E2E_PASSWORD
const DIR = process.env.ICARUS_E2E_DIR ?? join(tmpdir(), 'icarus-e2e')

// Six hours at 1 Hz, uploaded as two batches to stay well under the 20,000 series-row limit per batch.
const SAMPLES = 6 * 60 * 60
const HALF = SAMPLES / 2
const RR_WINDOW_SECS = 60 * 60
const MINUTES = 360

function fail(message) {
  console.error(`seed: ${message}`)
  process.exit(1)
}

// RFC 9562 UUIDv7: the id the contract asks clients to create (alarms, batches, bands).
function uuidv7() {
  const time = Date.now().toString(16).padStart(12, '0')
  const rand = randomBytes(10).toString('hex')
  const variant = ((parseInt(rand[3], 16) & 0x3) | 0x8).toString(16)
  return `${time.slice(0, 8)}-${time.slice(8, 12)}-7${rand.slice(0, 3)}-${variant}${rand.slice(4, 7)}-${rand.slice(7, 19)}`
}

async function call(method, path, { cookie, bearer, body, headers = {}, ok = [200] } = {}) {
  const init = { method, headers: { ...headers } }
  if (body !== undefined) {
    init.headers['content-type'] = 'application/json'
    init.body = JSON.stringify(body)
  }
  if (cookie) {
    init.headers.cookie = `icarus_session=${cookie}`
    if (method !== 'GET') init.headers['x-icarus-csrf'] = '1'
  }
  if (bearer) init.headers.authorization = `Bearer ${bearer}`
  const response = await fetch(BASE_URL + path, init)
  if (!ok.includes(response.status)) {
    const problem = await response.text()
    fail(`${method} ${path} answered ${response.status}: ${problem.slice(0, 200)}`)
  }
  return response.status === 204 ? null : response.json()
}

async function login() {
  const response = await fetch(`${BASE_URL}/v1/auth/login`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ email: EMAIL, password: PASSWORD }),
  })
  if (response.status !== 204) fail(`login answered ${response.status}`)
  for (const header of response.headers.getSetCookie()) {
    const match = /^icarus_session=([^;]+)/.exec(header)
    if (match) return match[1]
  }
  return fail('login sent no session cookie')
}

async function pairDevice(cookie, name) {
  const { code } = await call('POST', '/v1/devices/pairing-codes', { cookie })
  const paired = await call('POST', '/v1/devices/pair', {
    body: { code, name, model: 'iPhone 17 Pro', os_version: '26.0', app_version: '1.0.0' },
    ok: [201],
  })
  return { id: paired.device_id, name, token: paired.token }
}

// Deterministic synthetic signal: resting-range heart rate with slow and fast variation.
function bpmAt(sec) {
  return Math.round(64 + 12 * Math.sin(sec / 900) + 4 * Math.sin(sec / 37))
}

const round1 = (value) => Math.round(value * 10) / 10
const round2 = (value) => Math.round(value * 100) / 100
const clamp = (value, low, high) => Math.min(high, Math.max(low, value))

function buildBatch({ deviceId, band, startSec, endSec, sampleFrom, sampleTo, minuteFrom, minuteTo, rr, minuteStartSec }) {
  const hr = { ts_ms: [], bpm: [], source: [], contact: [] }
  for (let i = sampleFrom; i < sampleTo; i++) {
    const sec = startSec + i
    hr.ts_ms.push(sec * 1000)
    hr.bpm.push(bpmAt(sec))
    hr.source.push(1)
    hr.contact.push(true)
  }

  const minute_metrics = []
  for (let k = minuteFrom; k < minuteTo; k++) {
    const first = minuteStartSec + k * 60
    const last = Math.min(first + 59, endSec)
    const values = []
    for (let sec = first; sec <= last; sec++) values.push(bpmAt(sec))
    const avg = values.reduce((sum, value) => sum + value, 0) / values.length
    minute_metrics.push({
      minute_ms: first * 1000,
      hr_avg: round1(avg),
      hr_min: Math.min(...values),
      hr_max: Math.max(...values),
      hr_n: values.length,
      rmssd_ms: round1(38 + 10 * Math.sin(k / 50)),
      sdnn_ms: round1(48 + 8 * Math.sin(k / 60)),
      baevsky_sqrt: round1(8 + 2 * Math.sin(k / 30)),
      stress: clamp(Math.round(40 + 22 * Math.sin(k / 45) + 6 * Math.sin(k / 7)), 0, 100),
      stress_state: 'value',
      kcal: round2(1.1 + avg * 0.012),
      active_kcal: round2(Math.max(0, (avg - 70) / 40)),
      kcal_estimated: true,
      algo_version: 1,
      sync_rev: 1,
    })
  }

  return {
    schema: 1,
    batch_id: uuidv7(),
    device_id: deviceId,
    created_at: new Date().toISOString(),
    bands: [{ id: band.id, name: band.name, firmware: band.firmware }],
    hr: { band_id: band.id, ...hr },
    rr: rr ? { band_id: band.id, ...rr } : null,
    minute_metrics,
    events: [],
    alarm_deliveries: [],
    cursors: { hr_sample: sampleTo - 1, rr_interval: rr ? rr.seq.at(-1) : 0 },
  }
}

// R-R intervals for the last hour, one per beat at the seeded heart rate. Sized to fit the second batch.
function buildRr(startMs, endMs) {
  const rr = { ts_ms: [], seq: [], rr_ms: [], accepted: [] }
  let t = startMs
  let seq = 0
  while (t < endMs) {
    const rrMs = Math.round(60000 / bpmAt(Math.floor(t / 1000)))
    rr.ts_ms.push(t)
    rr.seq.push(seq)
    rr.rr_ms.push(rrMs)
    rr.accepted.push(true)
    t += rrMs
    seq += 1
  }
  return rr
}

async function upload(bearer, batch) {
  const result = await call('POST', '/v1/sync/batches', {
    bearer,
    body: batch,
    headers: { 'idempotency-key': batch.batch_id },
  })
  console.log(
    `seed: batch ${batch.hr.ts_ms.length} hr rows, ${batch.minute_metrics.length} minutes, ` +
      `${batch.rr ? batch.rr.ts_ms.length : 0} rr rows: hr inserted ${result.counts.hr.inserted}, ` +
      `minutes upserted ${result.counts.minute_metrics.upserted}`,
  )
  return result
}

async function main() {
  if (!PASSWORD) fail('ICARUS_E2E_PASSWORD is not set')

  const cookie = await login()
  await call('POST', '/v1/alarms', {
    cookie,
    ok: [201],
    body: {
      kind: 'scheduled',
      label: 'Front door',
      schedule: { time: '06:30', weekdays: [1, 2, 3, 4, 5] },
      rhythm: 'single',
      channels: ['phone'],
      enabled: true,
    },
  })

  const phone = await pairDevice(cookie, 'E2E iPhone')

  // Whole seconds, ending now, so Today always has samples in the user's current day.
  const endSec = Math.floor(Date.now() / 1000)
  const startSec = endSec - (SAMPLES - 1)
  const endMinuteSec = Math.floor(endSec / 60) * 60
  const minuteStartSec = endMinuteSec - (MINUTES - 1) * 60

  const band = { id: uuidv7(), name: 'WHOOP 4.0', firmware: '1.0.0' }
  const rr = buildRr(Math.max(startSec, endSec - RR_WINDOW_SECS) * 1000, endSec * 1000)

  const first = buildBatch({
    deviceId: phone.id,
    band,
    startSec,
    endSec,
    sampleFrom: 0,
    sampleTo: HALF,
    minuteFrom: 0,
    minuteTo: MINUTES / 2,
    rr: null,
    minuteStartSec,
  })
  const second = buildBatch({
    deviceId: phone.id,
    band,
    startSec,
    endSec,
    sampleFrom: HALF,
    sampleTo: SAMPLES,
    minuteFrom: MINUTES / 2,
    minuteTo: MINUTES,
    rr,
    minuteStartSec,
  })
  await upload(phone.token, first)
  await upload(phone.token, second)

  const alarms = await call('GET', '/v1/alarms', { cookie })
  const alarm = alarms.alarms.find((item) => item.label === 'Front door')
  if (!alarm) fail('seeded alarm not found')

  const sessionExpiry = Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60
  const storage = {
    cookies: [
      {
        name: 'icarus_session',
        value: cookie,
        domain: new URL(BASE_URL).hostname,
        path: '/',
        expires: sessionExpiry,
        httpOnly: true,
        secure: false,
        sameSite: 'Lax',
      },
    ],
    origins: [],
  }
  const seed = { alarm: { id: alarm.id, label: alarm.label }, phone }

  mkdirSync(DIR, { recursive: true })
  writeFileSync(join(DIR, 'storage.json'), JSON.stringify(storage, null, 2), { mode: 0o600 })
  writeFileSync(join(DIR, 'seed.json'), JSON.stringify(seed, null, 2), { mode: 0o600 })
  console.log(`seed: done, state in ${DIR}`)
}

await main()
