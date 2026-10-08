import { Link } from '@tanstack/react-router'
import { ErrorLine } from '@/components/error-line'
import { LoadingBlock } from '@/components/loading'
import { useNow } from '@/hooks/use-now'
import { describeError } from '@/lib/errors'
import { coverageLevel } from '@/lib/health'
import { useDaily, useMe } from '@/lib/queries'
import { addDays, dayInZone, formatDayTitle } from '@/lib/time'
import type { DailySummary } from '@/lib/types'

const WEEKS = 12
const WEEKDAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']
const LEVEL_LABEL = ['none', 'under 25 %', '25 to 49 %', '50 to 74 %', '75 % and over'] as const

// Shading uses foreground opacity only, so it reads in both themes (PLAN.md §15.3 rule 18).
const LEVEL_CLASS = [
  'bg-muted',
  'bg-foreground/15',
  'bg-foreground/35',
  'bg-foreground/60',
  'bg-foreground/90',
] as const

export function HistoryPage() {
  const me = useMe()
  const now = useNow(60_000)
  if (me.isPending) return <LoadingBlock className="h-72" />
  if (me.isError) return <ErrorLine message={describeError(me.error)} />
  return <HistoryView tz={me.data.tz} now={now} />
}

function HistoryView({ tz, now }: { tz: string; now: Date }) {
  const today = dayInZone(now.getTime(), tz)
  const start = gridStart(today)
  const daily = useDaily(start, today)

  if (daily.isError) return <ErrorLine message={describeError(daily.error)} />
  if (daily.isPending) return <LoadingBlock className="h-72" />

  const byDay = new Map<string, DailySummary>(daily.data.days.map((row) => [row.day, row]))

  return (
    <div className="flex flex-col gap-6">
      <section aria-labelledby="coverage-heading" className="flex flex-col gap-3">
        <h2 id="coverage-heading" className="text-xs font-medium">
          Last {WEEKS} weeks
        </h2>
        <div className="inline-grid grid-cols-[auto_repeat(12,max-content)] gap-1">
            {WEEKDAYS.map((weekday, row) => (
              <DayRow key={weekday} weekday={weekday} row={row} start={start} today={today} byDay={byDay} />
            ))}
        </div>
        <Legend />
      </section>
    </div>
  )
}

// Monday of the week that is WEEKS - 1 weeks before the current week.
export function gridStart(today: string): string {
  const [y, m, d] = today.split('-').map(Number)
  const weekday = (new Date(Date.UTC(y, m - 1, d)).getUTCDay() + 6) % 7
  return addDays(today, -weekday - (WEEKS - 1) * 7)
}

function DayRow({
  weekday,
  row,
  start,
  today,
  byDay,
}: {
  weekday: string
  row: number
  start: string
  today: string
  byDay: Map<string, DailySummary>
}) {
  return (
    <>
      <p className="self-center pr-2 text-xs text-muted-foreground">{weekday}</p>
      {Array.from({ length: WEEKS }, (_, week) => {
        const day = addDays(start, week * 7 + row)
        if (day > today) return <span key={day} aria-hidden className="size-5 md:size-6" />
        const coverage = byDay.get(day)?.coverage ?? 0
        const level = coverageLevel(coverage)
        const label = `${formatDayTitle(day)}, ${Math.round(coverage * 100)} % covered`
        return (
          <Link
            key={day}
            to="/history/$day"
            params={{ day }}
            aria-label={label}
            title={label}
            className={`size-5 md:size-6 ${LEVEL_CLASS[level]} hover:outline-2 hover:outline-offset-1 hover:outline-foreground focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring`}
          />
        )
      })}
    </>
  )
}

function Legend() {
  return (
    <div className="flex flex-wrap items-center gap-3 text-xs text-muted-foreground">
      <span>Coverage</span>
      {LEVEL_CLASS.map((className, level) => (
        <span key={level} className="flex items-center gap-1">
          <span aria-hidden className={`inline-block size-3 ${className}`} />
          {LEVEL_LABEL[level]}
        </span>
      ))}
    </div>
  )
}
