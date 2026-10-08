import type { ReactNode } from 'react'
import { TimeSeriesChart } from '@/components/charts/series-chart'
import { EmptyState } from '@/components/empty-state'
import { ErrorLine } from '@/components/error-line'
import { Panel, Stat } from '@/components/stat'
import { Skeleton } from '@/components/ui/skeleton'
import { useNow } from '@/hooks/use-now'
import { describeError } from '@/lib/errors'
import { formatInt } from '@/lib/format'
import { useDaily, useHr, useLiveHr, useMinutes, useSyncState } from '@/lib/queries'
import { addDays, dayRange, formatAgo, formatClock, formatDayShort, staleAge } from '@/lib/time'
import type { DailySummary, HrPoint, MinuteMetric } from '@/lib/types'

type Props = {
  day: string
  tz: string
  // Today shows the live sample and last sync; a past day shows only what was recorded for it.
  live: boolean
  emptyAction: ReactNode
  emptyMessage: string
}

// The widgets shared by Today and the history day view (PLAN.md §13.3).
export function DayDashboard({ day, tz, live, emptyAction, emptyMessage }: Props) {
  const now = useNow(live ? 5_000 : 60_000)
  const range = dayRange(day, tz, now)
  const minutes = useMinutes(range)
  const hr = useHr(range, '1m')
  // Seven days back, so the resting heart rate has a value even before today's night is complete.
  const daily = useDaily(addDays(day, -6), day)
  const liveHr = useLiveHr(live)
  const sync = useSyncState(live)

  const queries = [minutes, hr, daily, ...(live ? [liveHr, sync] : [])]
  const failed = queries.find((query) => query.isError)
  if (failed?.error) return <ErrorLine message={describeError(failed.error)} />

  const loading = queries.some((query) => query.isPending)
  if (loading) return <DashboardSkeleton live={live} />

  const minuteRows: MinuteMetric[] = minutes.data?.minutes ?? []
  const hrPoints: HrPoint[] = hr.data?.points ?? []
  const dayRow: DailySummary | undefined = daily.data?.days.find((row) => row.day === day)
  const rhr = latestRhr(daily.data?.days ?? [])
  const bpm = liveHr.data?.bpm ?? null
  const hasData = minuteRows.length > 0 || hrPoints.length > 0 || bpm !== null

  if (!hasData) {
    return <EmptyState message={emptyMessage} action={emptyAction} />
  }

  const liveAge = liveHr.data ? staleAge(liveHr.data.ts, now) : null
  const syncAge = sync.data?.last_batch_at ? formatAgo(now.getTime() - Date.parse(sync.data.last_batch_at)) : null

  return (
    <div className="flex flex-col gap-6">
      <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        {live && (
          <Panel title="Heart rate">
            <Stat
              label="Now"
              value={bpm}
              unit="bpm"
              caption={liveAge ? `Updated ${liveAge}` : undefined}
            />
          </Panel>
        )}
        <Panel title="Resting heart rate">
          <Stat
            label="Latest"
            value={rhr?.rhr ?? null}
            unit="bpm"
            caption={rhr ? `Night of ${formatDayShort(rhr.day)}` : undefined}
          />
        </Panel>
        <Panel title="Calories">
          <div className="grid grid-cols-2 gap-4">
            <Stat label="Total" value={dayRow?.kcal_total == null ? null : formatInt(dayRow.kcal_total)} unit="kcal" />
            <Stat label="Active" value={dayRow?.kcal_active == null ? null : formatInt(dayRow.kcal_active)} unit="kcal" />
          </div>
          <p className="text-xs text-muted-foreground">Estimated</p>
        </Panel>
        {live && (
          <Panel title="Sync">
            <Stat
              label="Last sync"
              value={sync.data?.last_batch_at ? formatClock(Date.parse(sync.data.last_batch_at), tz) : null}
              caption={syncAge ? syncAge : undefined}
            />
          </Panel>
        )}
      </div>

      <Panel title="Heart rate, 1 min">
        <TimeSeriesChart
          tz={tz}
          summary={hrSummary(hrPoints)}
          rows={hrPoints.map((point) => ({
            t: Date.parse(point.t),
            avg: point.avg,
            min: point.min,
            max: point.max,
          }))}
          series={[
            { key: 'avg', label: 'Average', tone: 'primary', unit: 'bpm' },
            { key: 'min', label: 'Minimum', tone: 'secondary', unit: 'bpm', hidden: true },
            { key: 'max', label: 'Maximum', tone: 'secondary', unit: 'bpm', hidden: true },
          ]}
        />
      </Panel>

      <Panel title="Stress">
        <TimeSeriesChart
          tz={tz}
          summary={stressSummary(minuteRows)}
          domain={[0, 100]}
          rows={minuteRows.map((minute) => ({
            t: Date.parse(minute.minute),
            stress: minute.stress,
          }))}
          series={[{ key: 'stress', label: 'Stress', tone: 'primary', unit: '' }]}
          ticks={[0, 33, 67, 100]}
        />
      </Panel>
    </div>
  )
}

function DashboardSkeleton({ live }: { live: boolean }) {
  return (
    <div className="flex flex-col gap-6" aria-busy="true" aria-label="Loading">
      <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        {Array.from({ length: live ? 4 : 2 }, (_, index) => (
          <Skeleton key={index} className="h-28" />
        ))}
      </div>
      <Skeleton className="h-72" />
      <Skeleton className="h-72" />
    </div>
  )
}

function latestRhr(days: DailySummary[]): { rhr: number; day: string } | null {
  for (const row of [...days].reverse()) {
    if (row.rhr !== null) return { rhr: row.rhr, day: row.day }
  }
  return null
}

function hrSummary(points: HrPoint[]): string {
  const values = points.map((point) => point.avg)
  if (values.length === 0) return 'Heart rate: no samples'
  const low = Math.min(...values)
  const high = Math.max(...values)
  return `Heart rate, ${values.length} minutes, from ${Math.round(low)} to ${Math.round(high)} bpm`
}

function stressSummary(minutes: MinuteMetric[]): string {
  const values = minutes.map((minute) => minute.stress).filter((value): value is number => value !== null)
  if (values.length === 0) return 'Stress: no values'
  const high = values.filter((value) => value >= 67).length
  return `Stress, ${values.length} minutes with a value, ${high} in the high band`
}
