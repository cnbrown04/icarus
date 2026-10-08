import type { Me, MinuteMetric } from './types'

// Heart-rate zones as a share of heart-rate reserve (PLAN.md §8.1, Karvonen).
export const HRR_ZONES = [
  { id: 'below', label: 'Under 50 %', from: -Infinity, to: 50 },
  { id: 'z1', label: '50–60 %', from: 50, to: 60 },
  { id: 'z2', label: '60–70 %', from: 60, to: 70 },
  { id: 'z3', label: '70–80 %', from: 70, to: 80 },
  { id: 'z4', label: '80–90 %', from: 80, to: 90 },
  { id: 'z5', label: '90 % and over', from: 90, to: Infinity },
] as const

export type HrZoneId = (typeof HRR_ZONES)[number]['id']

export function hrrPercent(bpm: number, rhr: number, hrMax: number): number {
  return ((bpm - rhr) / (hrMax - rhr)) * 100
}

export type HrMaxSource = { value: number; source: 'entered' | 'tanaka' }

// Entered HRmax wins; otherwise Tanaka from birth year (PLAN.md §8.1). Null when neither exists.
export function resolveHrMax(me: Pick<Me, 'hr_max' | 'birth_year'>, now: Date): HrMaxSource | null {
  if (me.hr_max !== null) return { value: me.hr_max, source: 'entered' }
  if (me.birth_year !== null) {
    const age = now.getUTCFullYear() - me.birth_year
    return { value: Math.round(208 - 0.7 * age), source: 'tanaka' }
  }
  return null
}

export type ZoneRow = { id: HrZoneId; label: string; minutes: number; share: number }

// Minutes in each zone. Points without an average are skipped.
export function zoneDistribution(bpms: number[], rhr: number, hrMax: number): ZoneRow[] {
  const counts = new Map<HrZoneId, number>(HRR_ZONES.map((zone) => [zone.id, 0]))
  let total = 0
  for (const bpm of bpms) {
    const pct = hrrPercent(bpm, rhr, hrMax)
    const zone = HRR_ZONES.find((z) => pct >= z.from && pct < z.to) ?? HRR_ZONES[0]
    counts.set(zone.id, (counts.get(zone.id) ?? 0) + 1)
    total += 1
  }
  return HRR_ZONES.map((zone) => {
    const minutes = counts.get(zone.id) ?? 0
    return { id: zone.id, label: zone.label, minutes, share: total === 0 ? 0 : minutes / total }
  })
}

export type StressBand = 'low' | 'moderate' | 'high'

// Bands for UI copy (PLAN.md §8.3).
export function stressBand(stress: number): StressBand {
  if (stress <= 33) return 'low'
  if (stress <= 66) return 'moderate'
  return 'high'
}

export const HIGH_STRESS_FROM = 67

export type HourlyKcal = { hour: number; kcal: number; active: number }

// Sums minute kcal into local hours 0-23. `hourOf` maps a minute to its local hour.
export function hourlyKcal(minutes: MinuteMetric[], hourOf: (minute: string) => number): HourlyKcal[] {
  const rows: HourlyKcal[] = Array.from({ length: 24 }, (_, hour) => ({ hour, kcal: 0, active: 0 }))
  for (const minute of minutes) {
    const row = rows[hourOf(minute.minute)]
    row.kcal += minute.kcal ?? 0
    row.active += minute.active_kcal ?? 0
  }
  return rows.map((row) => ({ hour: row.hour, kcal: round1(row.kcal), active: round1(row.active) }))
}

function round1(value: number): number {
  return Math.round(value * 10) / 10
}

// Coverage shading levels for the history grid: 0 (none) to 4 (full).
export function coverageLevel(coverage: number): 0 | 1 | 2 | 3 | 4 {
  if (coverage <= 0) return 0
  if (coverage < 0.25) return 1
  if (coverage < 0.5) return 2
  if (coverage < 0.75) return 3
  return 4
}

export type StressBin = { t: number; value: number; band: StressBand }

// Means of the stress minutes over fixed buckets, so a day fits as bars. Minutes without a value are skipped.
export function binStress(minutes: MinuteMetric[], binMinutes = 5): StressBin[] {
  const size = binMinutes * 60_000
  const sums = new Map<number, { sum: number; count: number }>()
  for (const minute of minutes) {
    if (minute.stress === null) continue
    const t = Math.floor(Date.parse(minute.minute) / size) * size
    const bin = sums.get(t) ?? { sum: 0, count: 0 }
    bin.sum += minute.stress
    bin.count += 1
    sums.set(t, bin)
  }
  return [...sums.entries()]
    .sort(([a], [b]) => a - b)
    .map(([t, { sum, count }]) => {
      const value = Math.round(sum / count)
      return { t, value, band: stressBand(value) }
    })
}

// Change of the latest value against the mean of the values before it. Oldest first; nulls are skipped.
export function changeAgainstMean(values: (number | null)[]): number | null {
  const present = values.filter((value): value is number => value !== null)
  if (present.length < 2) return null
  const latest = present[present.length - 1]
  const earlier = present.slice(0, -1)
  const mean = earlier.reduce((sum, value) => sum + value, 0) / earlier.length
  return Math.round(latest - mean)
}
