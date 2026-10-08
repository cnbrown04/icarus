import { describe, expect, it } from 'vitest'
import { coverageLevel, hourlyKcal, resolveHrMax, stressBand, zoneDistribution } from './health'
import type { MinuteMetric } from './types'

const now = new Date('2026-10-08T12:00:00Z')

describe('HRmax', () => {
  it('uses the entered value first', () => {
    expect(resolveHrMax({ hr_max: 190, birth_year: 1995 }, now)).toEqual({ value: 190, source: 'entered' })
  })

  it('estimates with Tanaka from birth year when none is entered', () => {
    // Age 31 in 2026: 208 - 0.7 * 31 = 186.3.
    expect(resolveHrMax({ hr_max: null, birth_year: 1995 }, now)).toEqual({ value: 186, source: 'tanaka' })
  })

  it('returns null when neither is known', () => {
    expect(resolveHrMax({ hr_max: null, birth_year: null }, now)).toBeNull()
  })
})

describe('zones', () => {
  it('counts minutes by share of heart-rate reserve', () => {
    // RHR 60, HRmax 160: reserve 100. 110 bpm is 50 %, 150 bpm is 90 %, 100 bpm is 40 %.
    const rows = zoneDistribution([110, 150, 100, 150], 60, 160)
    const counts = Object.fromEntries(rows.map((row) => [row.id, row.minutes]))
    expect(counts).toEqual({ below: 1, z1: 1, z2: 0, z3: 0, z4: 0, z5: 2 })
    expect(rows.find((row) => row.id === 'z5')?.share).toBe(0.5)
  })

  it('returns zero shares for no samples', () => {
    expect(zoneDistribution([], 60, 160).every((row) => row.share === 0)).toBe(true)
  })
})

describe('stress bands and coverage', () => {
  it('uses the bands from PLAN.md §8.3', () => {
    expect([stressBand(0), stressBand(33), stressBand(34), stressBand(66), stressBand(67)]).toEqual([
      'low',
      'low',
      'moderate',
      'moderate',
      'high',
    ])
  })

  it('buckets coverage into five shading levels', () => {
    expect([0, 0.1, 0.3, 0.6, 1].map(coverageLevel)).toEqual([0, 1, 2, 3, 4])
  })
})

describe('hourly calories', () => {
  it('sums minute kcal into local hours', () => {
    const minute = (hour: number, kcal: number, active: number): MinuteMetric => ({
      minute: `2026-10-07T${String(hour).padStart(2, '0')}:00:00Z`,
      hr_avg: 70,
      hr_min: 65,
      hr_max: 75,
      hr_n: 60,
      rmssd_ms: 30,
      sdnn_ms: 40,
      baevsky_sqrt: 9,
      stress: 40,
      stress_state: 'value',
      kcal,
      active_kcal: active,
      kcal_estimated: false,
    })
    const rows = hourlyKcal([minute(7, 1.5, 0.2), minute(7, 1.5, 0.3), minute(9, 2, 0)], (value) => new Date(value).getUTCHours())
    expect(rows[7]).toEqual({ hour: 7, kcal: 3, active: 0.5 })
    expect(rows[9]).toEqual({ hour: 9, kcal: 2, active: 0 })
    expect(rows).toHaveLength(24)
  })
})
