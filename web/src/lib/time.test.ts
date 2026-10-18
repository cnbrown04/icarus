import { describe, expect, it } from 'vitest'
import {
  addDays,
  dayInZone,
  dayRange,
  formatAgo,
  formatClock,
  formatDayTitle,
  isDay,
  staleAge,
  zonedMidnight,
} from './time'

const CHICAGO = 'America/Chicago'

describe('zoned days', () => {
  it('finds local midnight on a daylight-saving day', () => {
    // Central daylight time is UTC-5 on 2026-10-07.
    expect(zonedMidnight('2026-10-07', CHICAGO).toISOString()).toBe('2026-10-07T05:00:00.000Z')
  })

  it('moves to standard time after the change on 2026-11-01', () => {
    expect(zonedMidnight('2026-11-02', CHICAGO).toISOString()).toBe('2026-11-02T06:00:00.000Z')
  })

  it('names the local day of an instant', () => {
    // 03:00 UTC is 22:00 the previous evening in Chicago.
    expect(dayInZone(Date.parse('2026-10-07T03:00:00Z'), CHICAGO)).toBe('2026-10-06')
  })

  it('caps the range at now for today', () => {
    const now = new Date('2026-10-07T17:00:00Z')
    const { from, to } = dayRange('2026-10-07', CHICAGO, now)
    expect(from.toISOString()).toBe('2026-10-07T05:00:00.000Z')
    expect(to.toISOString()).toBe('2026-10-07T17:00:00.000Z')
  })

  it('returns the whole day for past days', () => {
    const { to } = dayRange('2026-10-06', CHICAGO, new Date('2026-10-08T12:00:00Z'))
    expect(to.toISOString()).toBe('2026-10-07T05:00:00.000Z')
  })

  it('adds days across month ends', () => {
    expect(addDays('2026-10-31', 1)).toBe('2026-11-01')
    expect(addDays('2026-03-01', -1)).toBe('2026-02-28')
  })

  it('validates YYYY-MM-DD and rejects impossible dates', () => {
    expect(isDay('2026-10-07')).toBe(true)
    expect(isDay('2026-02-30')).toBe(false)
    expect(isDay('07/10/2026')).toBe(false)
  })
})

describe('formatting', () => {
  it('formats clock time in the user zone', () => {
    expect(formatClock(Date.parse('2026-10-07T19:05:00Z'), CHICAGO)).toBe('14:05')
  })

  it('formats a day title without shifting the calendar date', () => {
    expect(formatDayTitle('2026-10-07')).toBe('Wed 7 Oct 2026')
  })

  it('describes ages in seconds, minutes, hours and days', () => {
    expect(formatAgo(45_000)).toBe('45 s ago')
    expect(formatAgo(3 * 60_000)).toBe('3 min ago')
    expect(formatAgo(2 * 3_600_000)).toBe('2 h ago')
    expect(formatAgo(3 * 24 * 3_600_000)).toBe('3 d ago')
  })

  it('shows an age only after 60 seconds', () => {
    const now = new Date('2026-10-07T12:00:00Z')
    expect(staleAge('2026-10-07T11:59:30Z', now)).toBeNull()
    expect(staleAge('2026-10-07T11:57:00Z', now)).toBe('3 min ago')
    expect(staleAge(null, now)).toBeNull()
  })
})
