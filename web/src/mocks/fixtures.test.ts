import { describe, expect, it } from 'vitest'
import { bucketPoints, dailySummary, minuteMetric, minutesBetween, rawPoints } from './fixtures'

describe('fixtures', () => {
  const from = Date.parse('2026-10-07T05:00:00Z')

  it('is deterministic per minute', () => {
    expect(minuteMetric(from + 600_000)).toEqual(minuteMetric(from + 600_000))
  })

  it('records most minutes of a day, with a few gaps', () => {
    const rows = minutesBetween(from, from + 24 * 3_600_000)
    expect(rows.length).toBeGreaterThan(1300)
    expect(rows.length).toBeLessThan(1440)
  })

  it('keeps every value inside its physiological range', () => {
    for (const row of minutesBetween(from, from + 24 * 3_600_000)) {
      expect(row.hr_avg).toBeGreaterThanOrEqual(45)
      expect(row.hr_avg).toBeLessThanOrEqual(175)
      if (row.stress !== null) expect(row.stress).toBeGreaterThanOrEqual(0)
      if (row.stress !== null) expect(row.stress).toBeLessThanOrEqual(100)
      expect(row.active_kcal).toBeGreaterThanOrEqual(0)
    }
  })

  it('buckets minutes into points and daily summaries', () => {
    const points = bucketPoints(from, from + 3_600_000, 300_000)
    expect(points.length).toBeGreaterThan(0)
    expect(points.every((point) => point.min <= point.avg && point.avg <= point.max)).toBe(true)
    expect(rawPoints(from, from + 60_000).length).toBeGreaterThan(0)

    const day = dailySummary('2026-10-07', from + 24 * 3_600_000)
    expect(day.coverage).toBeGreaterThan(0.9)
    expect(day.kcal_total).toBeGreaterThan(day.kcal_active ?? 0)
  })

  it('has no data before recording starts', () => {
    expect(dailySummary('2026-08-01', Date.parse('2026-08-02T00:00:00Z')).coverage).toBe(0)
  })
})
