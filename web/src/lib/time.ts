// Day and time helpers. Days are YYYY-MM-DD in the user's timezone (contract: Conventions).

const DAY = /^\d{4}-\d{2}-\d{2}$/

export function isDay(value: string): boolean {
  if (!DAY.test(value)) return false
  const [y, m, d] = value.split('-').map(Number)
  const date = new Date(Date.UTC(y, m - 1, d))
  return date.getUTCFullYear() === y && date.getUTCMonth() === m - 1 && date.getUTCDate() === d
}

// RFC 3339 with whole seconds, as the contract shows it.
export function toRfc3339(date: Date): string {
  return date.toISOString().replace(/\.\d{3}Z$/, 'Z')
}

function zonedParts(ms: number, tz: string): Record<string, number> {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: tz,
    hourCycle: 'h23',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  }).formatToParts(new Date(ms))
  const out: Record<string, number> = {}
  for (const part of parts) {
    if (part.type !== 'literal') out[part.type] = Number(part.value)
  }
  return out
}

// Offset of `tz` from UTC at instant `ms`, in milliseconds.
function offsetMs(ms: number, tz: string): number {
  const p = zonedParts(ms, tz)
  const asUtc = Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second)
  return asUtc - Math.floor(ms / 1000) * 1000
}

export function dayInZone(ms: number, tz: string): string {
  const p = zonedParts(ms, tz)
  return `${p.year}-${String(p.month).padStart(2, '0')}-${String(p.day).padStart(2, '0')}`
}

export function hourInZone(ms: number, tz: string): number {
  return zonedParts(ms, tz).hour
}

export function addDays(day: string, n: number): string {
  const [y, m, d] = day.split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, d + n)).toISOString().slice(0, 10)
}

// Instant of local midnight at the start of `day` in `tz`.
export function zonedMidnight(day: string, tz: string): Date {
  const [y, m, d] = day.split('-').map(Number)
  const wall = Date.UTC(y, m - 1, d)
  let instant = wall - offsetMs(wall, tz)
  // Recheck at the candidate instant: the offset differs across DST transitions.
  const corrected = wall - offsetMs(instant, tz)
  if (corrected !== instant) instant = corrected
  return new Date(instant)
}

// [from, to) for a whole local day, with `to` capped at `now`.
export function dayRange(day: string, tz: string, now: Date): { from: Date; to: Date } {
  const from = zonedMidnight(day, tz)
  const end = zonedMidnight(addDays(day, 1), tz)
  return { from, to: end.getTime() > now.getTime() ? now : end }
}

const clock = (tz: string) =>
  new Intl.DateTimeFormat('en-GB', { timeZone: tz, hour: '2-digit', minute: '2-digit', hourCycle: 'h23' })

const dateTime = (tz: string) =>
  new Intl.DateTimeFormat('en-GB', {
    timeZone: tz,
    weekday: 'short',
    day: 'numeric',
    month: 'short',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  })

export function formatClock(ms: number, tz: string): string {
  return clock(tz).format(new Date(ms))
}

export function formatDateTime(ms: number, tz: string): string {
  return dateTime(tz).format(new Date(ms))
}

// "Wed 7 Oct 2026" for a day key; the calendar date is the same in every zone.
export function formatDayTitle(day: string): string {
  const [y, m, d] = day.split('-').map(Number)
  const date = new Date(Date.UTC(y, m - 1, d))
  const part = (options: Intl.DateTimeFormatOptions) =>
    new Intl.DateTimeFormat('en-GB', { timeZone: 'UTC', ...options }).format(date)
  return `${part({ weekday: 'short' })} ${part({ day: 'numeric' })} ${part({ month: 'short' })} ${part({ year: 'numeric' })}`
}

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'] as const

// "8 Oct": short enough for dense axes. Fixed English names, so ICU's "Sept" does not shift the labels.
export function formatDayShort(day: string): string {
  const [, m, d] = day.split('-').map(Number)
  return `${d} ${MONTHS[m - 1]}`
}

// Live values show their age once they are older than this (PLAN.md §15.4 rule 24).
export const STALE_AFTER_MS = 60_000

// "updated 3 min ago" wording: "45 s ago", "3 min ago", "2 h ago", "1 d ago".
export function formatAgo(deltaMs: number): string {
  const seconds = Math.max(0, Math.round(deltaMs / 1000))
  if (seconds < 60) return `${seconds} s ago`
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes} min ago`
  const hours = Math.floor(minutes / 60)
  if (hours < 48) return `${hours} h ago`
  return `${Math.floor(hours / 24)} d ago`
}

// Age label only when the value is stale; fresh values carry no age.
export function staleAge(ts: string | null | undefined, now: Date): string | null {
  if (!ts) return null
  const delta = now.getTime() - new Date(ts).getTime()
  return delta > STALE_AFTER_MS ? formatAgo(delta) : null
}
