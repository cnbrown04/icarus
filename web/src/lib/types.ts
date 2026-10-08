// Response shapes from shared/api-contract.md. Keep in step with the contract.

export type Uuid = string

export type Me = {
  id: Uuid
  email: string
  tz: string
  formula_sex: 'male' | 'female' | null
  birth_year: number | null
  height_cm: number | null
  weight_kg: number | null
  hr_max: number | null
  version: number
}

export type MeUpdate = Partial<Pick<Me, 'tz' | 'formula_sex' | 'birth_year' | 'height_cm' | 'weight_kg' | 'hr_max'>>

export type Device = {
  id: Uuid
  name: string
  model: string
  os_version: string
  app_version: string
  created_at: string
  last_seen_at: string | null
  revoked_at: string | null
}

export type Band = {
  id: Uuid
  name: string
  firmware: string
  created_at: string
  last_seen_at: string | null
}

export type DevicesResponse = {
  devices: Device[]
  bands: Band[]
}

export type PairingCode = {
  code: string
  qr_svg: string
  expires_at: string
}

export type LiveHr = {
  bpm: number | null
  ts: string | null
}

export type HrResolution = 'raw' | '1m' | '5m' | '1h'

export type HrPoint = {
  t: string
  avg: number
  min: number
  max: number
}

export type HrResponse = {
  res: HrResolution
  points: HrPoint[]
}

// Contract leaves stress_state open. PLAN.md §8.3 names these states; "value" is the only one the contract shows.
export type StressState = 'value' | 'calibrating' | 'exertion' | 'insufficient data' | (string & {})

export type MinuteMetric = {
  minute: string
  hr_avg: number | null
  hr_min: number | null
  hr_max: number | null
  hr_n: number
  rmssd_ms: number | null
  sdnn_ms: number | null
  baevsky_sqrt: number | null
  stress: number | null
  stress_state: StressState
  kcal: number | null
  active_kcal: number | null
  kcal_estimated: boolean
}

export type MinutesResponse = {
  minutes: MinuteMetric[]
}

export type DailySummary = {
  day: string
  rhr: number | null
  hr_avg: number | null
  hr_max: number | null
  rmssd_night_ms: number | null
  stress_avg: number | null
  stress_high_minutes: number
  kcal_total: number | null
  kcal_active: number | null
  coverage: number
}

export type DailyResponse = {
  days: DailySummary[]
}

export type SyncCounts = {
  hr?: { inserted: number; duplicate: number }
  rr?: { inserted: number; duplicate: number }
  minute_metrics?: { upserted: number; stale: number }
  events?: { inserted: number; duplicate: number }
  alarm_deliveries?: { inserted: number; duplicate: number }
}

export type SyncBatchStatus = 'ok' | 'duplicate' | (string & {})

export type SyncBatch = {
  id: Uuid
  device_id: Uuid
  received_at: string
  counts: SyncCounts
  status: SyncBatchStatus
}

export type SyncState = {
  server_time: string
  last_batch_at: string | null
  batches: SyncBatch[]
}

export type Schedule = {
  time: string
  weekdays: number[]
}

export type RhythmStep = { type: 'buzz'; preset: number; loops: number } | { type: 'pause'; ms: number }

export type Rhythm = 'single' | 'double' | 'triple' | 'long' | 'ramp' | 'sos' | RhythmStep[]

export type AlarmChannel = 'phone' | 'band'

export type Alarm = {
  id: Uuid
  kind: 'scheduled' | 'webhook' | 'relay'
  label: string
  schedule: Schedule | null
  rhythm: Rhythm
  channels: AlarmChannel[]
  enabled: boolean
  version: number
  updated_at: string
  deleted_at: string | null
}

export type AlarmsResponse = {
  alarms: Alarm[]
}

export type Hook = {
  id: Uuid
  slug: string
  label: string
  alarm_id: Uuid | null
  auth_mode: 'hmac' | 'secret_url'
  rate_limit_per_min: number
  enabled: boolean
  url: string
  created_at: string
  last_triggered_at: string | null
  version: number
}

export type HooksResponse = {
  hooks: Hook[]
}

export type DispatchStatus = 'pending' | 'sent' | 'acked' | 'unacked' | 'failed'

export type Dispatch = {
  id: Uuid
  alarm_id: Uuid | null
  delivery_id: Uuid | null
  created_at: string
  attempts: number
  phone_status: string | null
  band_status: string | null
  acked_at: string | null
  status: DispatchStatus
  message: string | null
  rhythm: Rhythm
}

export type HookDelivery = {
  id: Uuid
  received_at: string
  status: 'accepted' | 'rejected' | 'rate_limited' | 'duplicate'
  signature_valid: boolean
  dispatch: Dispatch | null
}

export type HookDeliveriesResponse = {
  deliveries: HookDelivery[]
  next_cursor: string | null
}

export type AlarmInput = {
  id?: Uuid
  kind: Alarm['kind']
  label: string
  schedule: Schedule | null
  rhythm: Rhythm
  channels: AlarmChannel[]
  enabled: boolean
}

export type AlarmTest = {
  dispatch_id: Uuid
}

export type AlarmDispatchesResponse = {
  dispatches: Dispatch[]
}

export type HookCreate = {
  label: string
  alarm_id: Uuid | null
  auth_mode: Hook['auth_mode']
  rate_limit_per_min: number
}

export type HookUpdate = Partial<Pick<Hook, 'label' | 'alarm_id' | 'enabled' | 'rate_limit_per_min'>>

// The secret is returned once, on create and on rotate. The list never carries it.
export type CreatedHook = Hook & { secret: string }

export type RotatedSecret = {
  secret: string
}

export type WhoopStatus = {
  connected: boolean
  scopes: string[]
  connected_at: string | null
  last_webhook_at: string | null
}

// Live-fetched from WHOOP on each request; the server stores none of it (PLAN.md §6.3).
export type WhoopSummary = {
  recovery_score: number | null
  hrv_rmssd_milli: number | null
  resting_heart_rate: number | null
  strain: number | null
  kilojoule: number | null
  sleep_performance: number | null
}

// RFC 9457 problem document. `current` is present on 409 conflicts.
export type Problem = {
  type: string
  title: string
  status: number
  detail?: string
  current?: unknown
}
