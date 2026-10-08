// Deterministic fixtures for tests and the screenshot build (VITE_MSW=1). Values depend only on the minute
// (not on when the test runs), so the same range always returns the same numbers.
import type {
  Alarm,
  Band,
  DailySummary,
  Device,
  Dispatch,
  Hook,
  HookDelivery,
  HrPoint,
  Me,
  MinuteMetric,
  SyncBatch,
} from '@/lib/types'

export const FIXTURE_TZ = 'America/Chicago'
// Fixtures are generated at a fixed UTC-5 offset (Central daylight time). Good for October 2026 only; the
// app's own timezone maths still runs against the real tz database.
const LOCAL_OFFSET_MIN = -5 * 60
const MINUTE = 60_000
const DAY = 24 * 60 * MINUTE
// Recording starts on this local day, so the history grid shows empty days before it.
const RECORDING_START = Date.UTC(2026, 7, 20, 5)

export const USER: Me = {
  id: '0196a7c2-3f1e-7d4a-9b1e-5c2f8a6d1e01',
  email: 'caleb@example.com',
  tz: FIXTURE_TZ,
  formula_sex: 'male',
  birth_year: 1995,
  height_cm: 180,
  weight_kg: 80,
  hr_max: null,
  version: 3,
}

export const PHONE_ID = '0196a7c2-3f1e-7d4a-9b1e-5c2f8a6d1e10'
export const OLD_PHONE_ID = '0196a7c2-3f1e-7d4a-9b1e-5c2f8a6d1e11'
export const BAND_ID = '0196a7c2-3f1e-7d4a-9b1e-5c2f8a6d1e20'

// Deterministic pseudo-random in [0, 1) for a (value, salt) pair.
export function unit(value: number, salt: number): number {
  let x = Math.imul(value ^ Math.imul(salt, 0x27d4eb2d), 0x9e3779b1)
  x ^= x >>> 15
  x = Math.imul(x, 0x85ebca77)
  x ^= x >>> 13
  return (x >>> 0) / 4294967296
}

const BMR_KCAL_PER_MIN = (10 * 80 + 6.25 * 180 - 5 * 31 + 5) / 1440

export function localHour(ms: number): number {
  const local = ms + LOCAL_OFFSET_MIN * MINUTE
  return ((local % DAY) + DAY) % DAY / (60 * MINUTE)
}

export function localDay(ms: number): string {
  return new Date(ms + LOCAL_OFFSET_MIN * MINUTE).toISOString().slice(0, 10)
}

// The minute's metrics, or null where the band recorded nothing (roughly 3 % of minutes).
export function minuteMetric(ms: number): MinuteMetric | null {
  const minute = Math.floor(ms / MINUTE)
  if (ms < RECORDING_START) return null
  if (unit(minute, 1) < 0.03) return null

  const hour = localHour(ms)
  const asleep = hour < 6
  const exercising = hour >= 18.17 && hour < 18.67
  const circadian = Math.sin((hour - 9) / 24 * Math.PI * 2) * 4
  const noise = unit(minute, 2) * 6 - 3

  let hrAvg = asleep ? 54 + unit(minute, 3) * 5 : 68 + circadian + noise
  if (exercising) hrAvg = 128 + unit(minute, 4) * 22
  if (!asleep && !exercising && unit(minute, 5) < 0.04) hrAvg = 96 + unit(minute, 6) * 14
  hrAvg = Math.round(hrAvg * 10) / 10

  const hrN = 52 + Math.floor(unit(minute, 7) * 9)
  const hrMin = Math.round(hrAvg - 2 - unit(minute, 8) * 4)
  const hrMax = Math.round(hrAvg + 2 + unit(minute, 9) * 4)

  const rmssd = Math.round((asleep ? 46 : 30) + unit(minute, 10) * 14 - (exercising ? 14 : 0))
  const sdnn = Math.round(rmssd * 1.25 * 10) / 10
  const baevsky = Math.round((8 + unit(minute, 11) * 4) * 10) / 10

  const kcalFull = keytelKcalPerMin(hrAvg)
  const kcal = Math.max(BMR_KCAL_PER_MIN, kcalFull ?? BMR_KCAL_PER_MIN)
  const roundedKcal = Math.round(kcal * 1000) / 1000
  const activeKcal = Math.round(Math.max(0, roundedKcal - BMR_KCAL_PER_MIN) * 1000) / 1000

  let stress: number | null
  let stressState: MinuteMetric['stress_state'] = 'value'
  if (exercising) {
    stress = null
    stressState = 'exertion'
  } else {
    stress = Math.max(0, Math.min(100, Math.round(50 + (hrAvg - 70) * 1.1 - (rmssd - 35) * 0.9)))
  }

  return {
    minute: new Date(minute * MINUTE).toISOString().replace('.000Z', 'Z'),
    hr_avg: hrAvg,
    hr_min: hrMin,
    hr_max: hrMax,
    hr_n: hrN,
    rmssd_ms: rmssd,
    sdnn_ms: sdnn,
    baevsky_sqrt: baevsky,
    stress,
    stress_state: stressState,
    kcal: roundedKcal,
    active_kcal: activeKcal,
    kcal_estimated: hrN < 30,
  }
}

// Keytel et al. (2005), male, without VO2max (PLAN.md §8.4). Below the flex threshold the minute is resting.
function keytelKcalPerMin(hr: number): number | null {
  const flex = Math.max(90, 55 + 0.3 * (190 - 55))
  if (hr < flex) return null
  const kJ = -55.0969 + 0.6309 * hr + 0.1988 * 80 + 0.2017 * 31
  return kJ / 4.184
}

// Minutes with data in [from, to), one row per recorded minute.
export function minutesBetween(fromMs: number, toMs: number): MinuteMetric[] {
  const rows: MinuteMetric[] = []
  const start = Math.ceil(fromMs / MINUTE) * MINUTE
  for (let t = start; t < toMs; t += MINUTE) {
    const row = minuteMetric(t)
    if (row) rows.push(row)
  }
  return rows
}

// Bucket minutes into fixed-width points (1 m, 5 m, 1 h) with the sample-weighted average.
export function bucketPoints(fromMs: number, toMs: number, bucketMs: number): HrPoint[] {
  const points: HrPoint[] = []
  for (let start = Math.floor(fromMs / bucketMs) * bucketMs; start < toMs; start += bucketMs) {
    const rows = minutesBetween(Math.max(start, fromMs), Math.min(start + bucketMs, toMs))
    if (rows.length === 0) continue
    const weight = rows.reduce((sum, row) => sum + row.hr_n, 0)
    const avg = rows.reduce((sum, row) => sum + (row.hr_avg ?? 0) * row.hr_n, 0) / weight
    points.push({
      t: new Date(start).toISOString().replace('.000Z', 'Z'),
      avg: Math.round(avg * 10) / 10,
      min: Math.min(...rows.map((row) => row.hr_min ?? 0)),
      max: Math.max(...rows.map((row) => row.hr_max ?? 0)),
    })
  }
  return points
}

// One point per second for the raw range. Each second takes its minute's average, plus a little jitter.
export function rawPoints(fromMs: number, toMs: number): HrPoint[] {
  const points: HrPoint[] = []
  for (let t = Math.ceil(fromMs / 1000) * 1000; t < toMs; t += 1000) {
    const row = minuteMetric(Math.floor(t / MINUTE) * MINUTE)
    if (!row || row.hr_avg === null) continue
    const bpm = Math.round(row.hr_avg + (unit(t / 1000, 12) - 0.5) * 4)
    points.push({ t: new Date(t).toISOString().replace('.000Z', 'Z'), avg: bpm, min: bpm, max: bpm })
  }
  return points
}

export function dailySummary(day: string, now: number): DailySummary {
  const dayStart = Date.parse(`${day}T05:00:00Z`)
  const dayEnd = dayStart + DAY
  const rows = minutesBetween(dayStart, Math.min(dayEnd, now))
  const elapsed = Math.max(0, Math.min(1440, Math.floor((Math.min(dayEnd, now) - dayStart) / MINUTE)))
  if (rows.length === 0) {
    return {
      day,
      rhr: null,
      hr_avg: null,
      hr_max: null,
      rmssd_night_ms: null,
      stress_avg: null,
      stress_high_minutes: 0,
      kcal_total: null,
      kcal_active: null,
      coverage: 0,
    }
  }
  const nightRows = rows.filter((row) => localHour(Date.parse(row.minute)) < 6)
  const night5 = nightRows.length >= 5 ? Math.min(...nightRows.map((row) => row.hr_avg ?? 999)) : null
  const withStress = rows.filter((row) => row.stress !== null)
  const stressAvg = withStress.length === 0 ? null : withStress.reduce((sum, row) => sum + (row.stress ?? 0), 0) / withStress.length
  const hrAvgs = rows.map((row) => row.hr_avg ?? 0)
  return {
    day,
    rhr: night5 === null ? null : Math.round(night5),
    hr_avg: Math.round((hrAvgs.reduce((a, b) => a + b, 0) / hrAvgs.length) * 10) / 10,
    hr_max: Math.max(...rows.map((row) => row.hr_max ?? 0)),
    rmssd_night_ms: nightRows.length === 0 ? null : Math.round(nightRows.reduce((sum, row) => sum + (row.rmssd_ms ?? 0), 0) / nightRows.length),
    stress_avg: stressAvg === null ? null : Math.round(stressAvg * 10) / 10,
    stress_high_minutes: withStress.filter((row) => (row.stress ?? 0) >= 67).length,
    kcal_total: Math.round(rows.reduce((sum, row) => sum + (row.kcal ?? 0), 0) * 10) / 10,
    kcal_active: Math.round(rows.reduce((sum, row) => sum + (row.active_kcal ?? 0), 0) * 10) / 10,
    coverage: elapsed === 0 ? 0 : Math.min(1, rows.length / elapsed),
  }
}

export function devicesFor(now: number): Device[] {
  return [
  {
    id: PHONE_ID,
    name: "Caleb's iPhone",
    model: 'iPhone 17 Pro Max',
    os_version: '26.0',
    app_version: '0.4.0',
    created_at: '2026-08-20T14:02:00Z',
    last_seen_at: new Date(now - 2 * MINUTE).toISOString(),
    revoked_at: null,
  },
  {
    id: OLD_PHONE_ID,
    name: 'iPhone 15',
    model: 'iPhone 15',
    os_version: '18.6',
    app_version: '0.2.1',
    created_at: '2026-08-20T14:10:00Z',
    last_seen_at: '2026-09-01T09:12:00Z',
    revoked_at: '2026-09-01T09:30:00Z',
  },
  ]
}

export function bandsFor(now: number): Band[] {
  return [
    {
      id: BAND_ID,
      name: 'WHOOP 4.0',
      firmware: '4.0.9',
      created_at: '2026-08-20T14:04:00Z',
      last_seen_at: new Date(now - 4 * MINUTE).toISOString(),
    },
  ]
}

export const ALARMS: Alarm[] = [
  {
    id: '0196a7c2-3f1e-7d4a-9b1e-5c2f8a6d1e30',
    kind: 'scheduled',
    label: 'Wake up',
    schedule: { time: '06:30', weekdays: [1, 2, 3, 4, 5] },
    rhythm: 'double',
    channels: ['phone', 'band'],
    enabled: true,
    version: 7,
    updated_at: '2026-09-28T19:00:00Z',
    deleted_at: null,
  },
  {
    id: '0196a7c2-3f1e-7d4a-9b1e-5c2f8a6d1e31',
    kind: 'scheduled',
    label: 'Weekend',
    schedule: { time: '08:30', weekdays: [6, 7] },
    rhythm: [
      { type: 'buzz', preset: 2, loops: 1 },
      { type: 'pause', ms: 300 },
      { type: 'buzz', preset: 2, loops: 1 },
    ],
    channels: ['phone'],
    enabled: false,
    version: 2,
    updated_at: '2026-09-12T08:00:00Z',
    deleted_at: null,
  },
  {
    id: '0196a7c2-3f1e-7d4a-9b1e-5c2f8a6d1e32',
    kind: 'webhook',
    label: 'Front door',
    schedule: null,
    rhythm: 'long',
    channels: ['phone'],
    enabled: true,
    version: 1,
    updated_at: '2026-09-20T10:00:00Z',
    deleted_at: null,
  },
]

export const HOOKS: Hook[] = [
  {
    id: '0196a7c2-3f1e-7d4a-9b1e-5c2f8a6d1e40',
    slug: 'f7k2m9',
    label: 'Front door',
    alarm_id: ALARMS[2].id,
    auth_mode: 'hmac',
    rate_limit_per_min: 10,
    enabled: true,
    url: 'https://icarus.example.com/v1/hooks/f7k2m9',
    created_at: '2026-09-20T10:00:00Z',
    last_triggered_at: '2026-10-06T21:14:00Z',
    version: 1,
  },
  {
    id: '0196a7c2-3f1e-7d4a-9b1e-5c2f8a6d1e41',
    slug: 'q4xw8r',
    label: 'Home Assistant',
    alarm_id: ALARMS[0].id,
    auth_mode: 'secret_url',
    rate_limit_per_min: 5,
    enabled: false,
    url: 'https://icarus.example.com/v1/hooks/q4xw8r',
    created_at: '2026-09-22T12:00:00Z',
    last_triggered_at: null,
    version: 2,
  },
]

export function deliveriesFor(hookId: string, now: number): HookDelivery[] {
  const dispatch = (index: number): Dispatch => ({
    id: `0196a7c2-3f1e-7d4a-9b1e-5c2f8a6e00${index}0`,
    alarm_id: ALARMS[2].id,
    delivery_id: null,
    created_at: new Date(now - index * 3_600_000).toISOString(),
    attempts: 1,
    phone_status: 'ok',
    band_status: null,
    acked_at: new Date(now - index * 3_600_000 + 2000).toISOString(),
    status: 'acked',
    message: 'Front door opened',
    rhythm: 'long',
  })
  return [
    { id: `${hookId}-d1`, received_at: new Date(now - 3_600_000).toISOString(), status: 'accepted', signature_valid: true, dispatch: dispatch(1) },
    { id: `${hookId}-d2`, received_at: new Date(now - 7_200_000).toISOString(), status: 'rate_limited', signature_valid: true, dispatch: null },
    { id: `${hookId}-d3`, received_at: new Date(now - 9_000_000).toISOString(), status: 'rejected', signature_valid: false, dispatch: null },
  ]
}

export function syncBatches(now: number): SyncBatch[] {
  return Array.from({ length: 12 }, (_, index) => ({
    id: `0196a7c2-3f1e-7d4a-9b1e-5c2f8a6f${String(index).padStart(4, '0')}`,
    device_id: PHONE_ID,
    received_at: new Date(now - (4 + index * 5) * MINUTE).toISOString(),
    counts: {
      hr: { inserted: 300, duplicate: 0 },
      rr: { inserted: 276, duplicate: 0 },
      minute_metrics: { upserted: 5, stale: 0 },
      events: { inserted: 0, duplicate: 0 },
      alarm_deliveries: { inserted: 0, duplicate: 0 },
    },
    status: 'ok',
  }))
}

// Local day key for the fixture window, used by the history grid tests.
export const FIXTURE_DAY = '2026-10-07'
