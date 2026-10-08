import { http, HttpResponse, type HttpHandler } from 'msw'
import {
  ALARMS,
  bandsFor,
  bucketPoints,
  dailySummary,
  devicesFor,
  deliveriesFor,
  HOOKS,
  minuteMetric,
  PHONE_ID,
  rawPoints,
  syncBatches,
  USER,
} from './fixtures'
import type { Alarm, Hook, Me, MeUpdate } from '@/lib/types'

// In-memory state so writes made during a test or a screenshot session are visible to later reads.
type State = {
  me: Me
  alarms: Alarm[]
  hooks: Hook[]
  revoked: Set<string>
}

export function createState(): State {
  return {
    me: { ...USER },
    alarms: structuredClone(ALARMS),
    hooks: structuredClone(HOOKS),
    revoked: new Set(),
  }
}

const MINUTE_MS = 60_000
const HOUR_MS = 3_600_000

// Day summaries for past days never change, so they are computed once.
const dailyCache = new Map<string, ReturnType<typeof dailySummary>>()

function problem(status: number, slug: string, title: string, detail?: string, extra?: object) {
  return HttpResponse.json(
    { type: `urn:icarus:problem:${slug}`, title, status, ...(detail ? { detail } : {}), ...extra },
    { status, headers: { 'Content-Type': 'application/problem+json' } },
  )
}

// The website's writes need the CSRF header (contract: Auth). Mocks enforce it so the client is tested for it.
function csrfOk(request: Request): boolean {
  if (request.method === 'GET') return true
  return request.headers.get('X-Icarus-CSRF') === '1'
}

const QR_MODULES = 21

// A stand-in QR: a deterministic square grid. It does not encode the pairing URL, so it is for layout only.
function fakeQrSvg(code: string): string {
  let seed = [...code].reduce((sum, char) => (sum * 31 + char.charCodeAt(0)) >>> 0, 7)
  const cells: string[] = []
  for (let y = 0; y < QR_MODULES; y++) {
    for (let x = 0; x < QR_MODULES; x++) {
      seed = (Math.imul(seed, 1103515245) + 12345) >>> 0
      if ((seed >>> 16) & 1) cells.push(`<rect x="${x}" y="${y}" width="1" height="1"/>`)
    }
  }
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="-2 -2 ${QR_MODULES + 4} ${QR_MODULES + 4}" fill="#000"><rect x="-2" y="-2" width="${QR_MODULES + 4}" height="${QR_MODULES + 4}" fill="#fff"/>${cells.join('')}</svg>`
}

const CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'

export function createHandlers(state: State = createState()): HttpHandler[] {
  return [
    http.post('/v1/auth/login', async ({ request }) => {
      const body = (await request.json()) as { email?: string; password?: string }
      if (!body.password || body.password === 'wrong') {
        return problem(401, 'unauthorized', 'Unauthorized', 'Email or password is incorrect.')
      }
      return new HttpResponse(null, { status: 204 })
    }),

    http.post('/v1/auth/logout', () => new HttpResponse(null, { status: 204 })),

    http.get('/v1/me', () => HttpResponse.json(state.me)),

    http.patch('/v1/me', async ({ request }) => {
      if (!csrfOk(request)) return problem(403, 'forbidden', 'Forbidden')
      const ifMatch = request.headers.get('If-Match')
      if (ifMatch === null) return problem(428, 'validation', 'Precondition required', 'If-Match is required.')
      if (Number(ifMatch) !== state.me.version) {
        return problem(409, 'conflict', 'Conflict', 'The profile changed.', { current: state.me })
      }
      const changes = (await request.json()) as MeUpdate
      state.me = { ...state.me, ...changes, version: state.me.version + 1 }
      return HttpResponse.json(state.me)
    }),

    http.delete('/v1/me', async ({ request }) => {
      if (!csrfOk(request)) return problem(403, 'forbidden', 'Forbidden')
      const body = (await request.json()) as { confirm?: string }
      if (body.confirm !== state.me.email) {
        return problem(400, 'validation', 'Bad request', 'Type your email address to confirm.')
      }
      return new HttpResponse(null, { status: 204 })
    }),

    http.post('/v1/devices/pairing-codes', ({ request }) => {
      if (!csrfOk(request)) return problem(403, 'forbidden', 'Forbidden')
      const code = Array.from(crypto.getRandomValues(new Uint8Array(8)), (byte) => CODE_ALPHABET[byte % CODE_ALPHABET.length]).join('')
      return HttpResponse.json({
        code,
        qr_svg: fakeQrSvg(code),
        expires_at: new Date(Date.now() + 10 * MINUTE_MS).toISOString(),
      })
    }),

    http.get('/v1/devices', () => {
      const now = Date.now()
      const devices = devicesFor(now).map((device) =>
        state.revoked.has(device.id) && device.revoked_at === null
          ? { ...device, revoked_at: new Date(now).toISOString() }
          : device,
      )
      return HttpResponse.json({ devices, bands: bandsFor(now) })
    }),

    http.delete('/v1/devices/:id', ({ params, request }) => {
      if (!csrfOk(request)) return problem(403, 'forbidden', 'Forbidden')
      const id = String(params.id)
      if (!devicesFor(Date.now()).some((device) => device.id === id)) {
        return problem(404, 'not-found', 'Not found')
      }
      state.revoked.add(id)
      return new HttpResponse(null, { status: 204 })
    }),

    http.get('/v1/metrics/live', () => {
      const now = Date.now()
      // The live sample is the current minute's average, reported 20 s old so it is not yet stale.
      const row = minuteMetric(Math.floor(now / MINUTE_MS) * MINUTE_MS)
      if (!row || row.hr_avg === null) return HttpResponse.json({ bpm: null, ts: null })
      return HttpResponse.json({ bpm: Math.round(row.hr_avg), ts: new Date(now - 20_000).toISOString() })
    }),

    http.get('/v1/metrics/hr', ({ request }) => {
      const url = new URL(request.url)
      const from = Date.parse(url.searchParams.get('from') ?? '')
      const to = Date.parse(url.searchParams.get('to') ?? '')
      const res = url.searchParams.get('res') ?? '1m'
      if (!Number.isFinite(from) || !Number.isFinite(to) || to <= from) {
        return problem(400, 'validation', 'Bad request', 'from and to must be RFC 3339 with from before to.')
      }
      if (res === 'raw' && to - from > 6 * HOUR_MS) {
        return problem(400, 'validation', 'Bad request', 'raw is allowed for ranges up to 6 h.')
      }
      if ((res === '1m' || res === '5m') && to - from > 14 * 24 * HOUR_MS) {
        return problem(400, 'validation', 'Bad request', 'Ranges over 14 d need the daily summary.')
      }
      const bucket = { raw: 0, '1m': MINUTE_MS, '5m': 5 * MINUTE_MS, '1h': HOUR_MS }[res] ?? MINUTE_MS
      const points = res === 'raw' ? rawPoints(from, to) : bucketPoints(from, to, bucket)
      return HttpResponse.json({ res, points })
    }),

    http.get('/v1/metrics/minutes', ({ request }) => {
      const url = new URL(request.url)
      const from = Date.parse(url.searchParams.get('from') ?? '')
      const to = Date.parse(url.searchParams.get('to') ?? '')
      if (!Number.isFinite(from) || !Number.isFinite(to) || to <= from) {
        return problem(400, 'validation', 'Bad request', 'from and to must be RFC 3339 with from before to.')
      }
      const minutes: ReturnType<typeof minuteMetric>[] = []
      for (let t = Math.ceil(from / MINUTE_MS) * MINUTE_MS; t < to; t += MINUTE_MS) {
        minutes.push(minuteMetric(t))
      }
      return HttpResponse.json({ minutes: minutes.filter((row) => row !== null) })
    }),

    http.get('/v1/metrics/daily', ({ request }) => {
      const url = new URL(request.url)
      const fromDay = url.searchParams.get('from') ?? ''
      const toDay = url.searchParams.get('to') ?? ''
      if (!/^\d{4}-\d{2}-\d{2}$/.test(fromDay) || !/^\d{4}-\d{2}-\d{2}$/.test(toDay)) {
        return problem(400, 'validation', 'Bad request', 'from and to must be YYYY-MM-DD.')
      }
      const now = Date.now()
      const days: ReturnType<typeof dailySummary>[] = []
      for (let day = fromDay; day <= toDay; day = nextDay(day)) {
        const dayEnd = Date.parse(`${day}T05:00:00Z`) + 24 * HOUR_MS
        const cached = dailyCache.get(day)
        if (cached && dayEnd <= now) {
          days.push(cached)
          continue
        }
        const summary = dailySummary(day, now)
        if (dayEnd <= now) dailyCache.set(day, summary)
        days.push(summary)
      }
      return HttpResponse.json({ days })
    }),

    http.get('/v1/sync/state', () => {
      const now = Date.now()
      const batches = syncBatches(now)
      return HttpResponse.json({
        server_time: new Date(now).toISOString(),
        last_batch_at: batches[0]?.received_at ?? null,
        batches: batches.map((batch) => ({ ...batch, device_id: PHONE_ID })),
      })
    }),

    http.get('/v1/alarms', () => HttpResponse.json({ alarms: state.alarms.filter((alarm) => !alarm.deleted_at) })),

    http.post('/v1/alarms', async ({ request }) => {
      if (!csrfOk(request)) return problem(403, 'forbidden', 'Forbidden')
      const body = (await request.json()) as Omit<Alarm, 'version' | 'updated_at' | 'deleted_at'> & { id?: string }
      const alarm: Alarm = {
        ...body,
        id: body.id ?? crypto.randomUUID(),
        version: 1,
        updated_at: new Date().toISOString(),
        deleted_at: null,
      }
      state.alarms.push(alarm)
      return HttpResponse.json(alarm, { status: 201 })
    }),

    http.patch('/v1/alarms/:id', async ({ params, request }) => {
      if (!csrfOk(request)) return problem(403, 'forbidden', 'Forbidden')
      const alarm = state.alarms.find((item) => item.id === params.id)
      if (!alarm) return problem(404, 'not-found', 'Not found')
      const ifMatch = request.headers.get('If-Match')
      if (ifMatch !== null && Number(ifMatch) !== alarm.version) {
        return problem(409, 'conflict', 'Conflict', 'The alarm changed.', { current: alarm })
      }
      Object.assign(alarm, await request.json(), { version: alarm.version + 1, updated_at: new Date().toISOString() })
      return HttpResponse.json(alarm)
    }),

    http.delete('/v1/alarms/:id', ({ params, request }) => {
      if (!csrfOk(request)) return problem(403, 'forbidden', 'Forbidden')
      const alarm = state.alarms.find((item) => item.id === params.id)
      if (!alarm) return problem(404, 'not-found', 'Not found')
      alarm.deleted_at = new Date().toISOString()
      alarm.version += 1
      return new HttpResponse(null, { status: 204 })
    }),

    http.post('/v1/alarms/:id/test', ({ params, request }) => {
      if (!csrfOk(request)) return problem(403, 'forbidden', 'Forbidden')
      return HttpResponse.json({ dispatch_id: `test-${String(params.id)}` }, { status: 202 })
    }),

    http.get('/v1/alarm-dispatches', () => HttpResponse.json({ dispatches: [] })),

    http.get('/v1/hooks', () => HttpResponse.json({ hooks: state.hooks })),

    http.post('/v1/hooks', async ({ request }) => {
      if (!csrfOk(request)) return problem(403, 'forbidden', 'Forbidden')
      const body = (await request.json()) as Pick<Hook, 'label' | 'alarm_id' | 'auth_mode'> & { rate_limit_per_min?: number }
      const slug = crypto.randomUUID().slice(0, 6)
      const hook: Hook = {
        id: crypto.randomUUID(),
        slug,
        label: body.label,
        alarm_id: body.alarm_id,
        auth_mode: body.auth_mode,
        rate_limit_per_min: body.rate_limit_per_min ?? 10,
        enabled: true,
        url: `https://icarus.example.com/v1/hooks/${slug}`,
        created_at: new Date().toISOString(),
        last_triggered_at: null,
        version: 1,
      }
      state.hooks.push(hook)
      return HttpResponse.json({ ...hook, secret: 'c2VjcmV0LWZpeHR1cmUtMzItYnl0ZXMtYmFzZTY0dXJs' }, { status: 201 })
    }),

    http.patch('/v1/hooks/:id', async ({ params, request }) => {
      if (!csrfOk(request)) return problem(403, 'forbidden', 'Forbidden')
      const hook = state.hooks.find((item) => item.id === params.id)
      if (!hook) return problem(404, 'not-found', 'Not found')
      Object.assign(hook, await request.json(), { version: hook.version + 1 })
      return HttpResponse.json(hook)
    }),

    http.delete('/v1/hooks/:id', ({ params, request }) => {
      if (!csrfOk(request)) return problem(403, 'forbidden', 'Forbidden')
      state.hooks = state.hooks.filter((item) => item.id !== params.id)
      return new HttpResponse(null, { status: 204 })
    }),

    http.post('/v1/hooks/:id/rotate-secret', ({ request }) => {
      if (!csrfOk(request)) return problem(403, 'forbidden', 'Forbidden')
      return HttpResponse.json({ secret: 'cm90YXRlZC1maXh0dXJlLXNlY3JldC0zMi1ieXRlcw' })
    }),

    http.get('/v1/hooks/:id/deliveries', ({ params }) =>
      HttpResponse.json({ deliveries: deliveriesFor(String(params.id), Date.now()), next_cursor: null }),
    ),

    http.get('/v1/export', () =>
      new HttpResponse(
        [
          JSON.stringify({ kind: 'me', email: state.me.email, tz: state.me.tz }),
          JSON.stringify({ kind: 'device', name: "Caleb's iPhone" }),
        ].join('\n') + '\n',
        { headers: { 'Content-Type': 'application/x-ndjson' } },
      ),
    ),
  ]
}

function nextDay(day: string): string {
  return new Date(Date.parse(`${day}T12:00:00Z`) + 24 * HOUR_MS).toISOString().slice(0, 10)
}

