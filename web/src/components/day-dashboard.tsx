import type { Icon } from '@phosphor-icons/react'
import {
  ArrowsClockwiseIcon,
  FlameIcon,
  GaugeIcon,
  HeartbeatIcon,
  HeartIcon,
  TargetIcon,
  WaveformIcon,
} from '@phosphor-icons/react'
import type { ReactNode } from 'react'
import { TimeBarChart, TimeSeriesChart } from '@/components/charts/series-chart'
import { EmptyState } from '@/components/empty-state'
import { ErrorLine } from '@/components/error-line'
import { MetricBand, BandLegend, bandFill, bandTone } from '@/components/metric-band'
import { SectionCard } from '@/components/section-card'
import { StatTile, type Delta } from '@/components/stat-tile'
import { SyncStatusBadge } from '@/components/sync-status-badge'
import { Skeleton } from '@/components/ui/skeleton'
import { ZoneBar } from '@/components/zone-bar'
import { useNow } from '@/hooks/use-now'
import { describeError } from '@/lib/errors'
import { formatInt } from '@/lib/format'
import { changeAgainstMean, binStress, resolveHrMax, stressBand, zoneDistribution } from '@/lib/health'
import { useDaily, useHr, useLiveHr, useMe, useMinutes, useSyncState } from '@/lib/queries'
import { addDays, dayRange, formatClock, formatDayShort, staleAge } from '@/lib/time'
import type { DailySummary, HrPoint, MinuteMetric } from '@/lib/types'

type Props = {
  day: string
  tz: string
  // Today shows the live sample and last sync; a past day shows only what was recorded for it.
  live: boolean
  emptyIcon: Icon
  emptyAction: ReactNode
  emptyMessage: string
}

// The widgets shared by Today and the history day view (PLAN.md §13.3).
export function DayDashboard({ day, tz, live, emptyIcon, emptyAction, emptyMessage }: Props) {
  const now = useNow(live ? 5_000 : 60_000)
  const me = useMe()
  const range = dayRange(day, tz, now)
  const minutes = useMinutes(range)
  const hr = useHr(range, '1m')
  // Seven days back, so the resting heart rate and HRV have a value and a 7-day trend before today's night is complete.
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
  const recent: DailySummary[] = daily.data?.days ?? []
  const dayRow = recent.find((row) => row.day === day)
  const rhr = latestOf(recent, (row) => row.rhr)
  const hrv = latestOf(recent, (row) => row.rmssd_night_ms)
  const bpm = liveHr.data?.bpm ?? null
  const hasData = minuteRows.length > 0 || hrPoints.length > 0 || bpm !== null

  if (!hasData) {
    return <EmptyState icon={emptyIcon} message={emptyMessage} action={emptyAction} />
  }

  const liveAge = liveHr.data ? staleAge(liveHr.data.ts, now) : null
  const lastBatch = sync.data?.last_batch_at ?? null
  const latestStress = [...minuteRows].reverse().find((minute) => minute.stress !== null)?.stress ?? null
  const stress = live ? latestStress : (dayRow?.stress_avg ?? null)
  const stressBandNow = stress === null ? null : stressBand(Math.round(stress))
  const hrMax = me.data ? resolveHrMax(me.data, now) : null
  const zones =
    rhr && hrMax && hrPoints.length > 0 ? zoneDistribution(hrPoints.map((point) => point.avg), rhr.value, hrMax.value) : null
  const bins = binStress(minuteRows)

  return (
    <div className="flex flex-col gap-6">
      <div className={live ? 'grid grid-cols-2 gap-4 xl:grid-cols-5' : 'grid grid-cols-2 gap-4 xl:grid-cols-4'}>
        {live && (
          <StatTile
            icon={HeartbeatIcon}
            label="Heart rate"
            value={bpm}
            unit="bpm"
            tone="hr"
            caption={liveAge ? `Updated ${liveAge}` : 'Live'}
          />
        )}
        <StatTile
          icon={HeartIcon}
          label="Resting heart rate"
          value={rhr?.value ?? null}
          unit="bpm"
          tone="hr"
          delta={deltaOf(changeAgainstMean(recent.map((row) => row.rhr)), 'bpm', 'bad')}
          sparkline={presentValues(recent.map((row) => row.rhr))}
          caption={rhr ? `Night of ${formatDayShort(rhr.day)}` : undefined}
        />
        <StatTile
          icon={WaveformIcon}
          label="HRV, RMSSD"
          value={hrv?.value ?? null}
          unit="ms"
          tone="hrv"
          delta={deltaOf(changeAgainstMean(recent.map((row) => row.rmssd_night_ms)), 'ms', 'good')}
          sparkline={presentValues(recent.map((row) => row.rmssd_night_ms))}
          caption={hrv ? `Night of ${formatDayShort(hrv.day)}` : undefined}
        />
        <StatTile
          icon={GaugeIcon}
          label="Stress"
          value={stress === null ? null : formatInt(stress)}
          unit="/ 100"
          tone={stressBandNow ? bandTone(stressBandNow) : 'neutral'}
          caption={stressBandNow ? <MetricBand band={stressBandNow} /> : undefined}
        />
        <StatTile
          icon={FlameIcon}
          label="Calories"
          value={dayRow?.kcal_total == null ? null : formatInt(dayRow.kcal_total)}
          unit="kcal"
          // Five tiles on a phone leave one alone in the last row, so it spans both columns there.
          className={live ? 'col-span-2 xl:col-span-1' : undefined}
          caption={
            <>
              <span className="block">
                Active {dayRow?.kcal_active == null ? '—' : formatInt(dayRow.kcal_active)} kcal
              </span>
              <span className="block">Estimated</span>
            </>
          }
        />
      </div>

      <SectionCard title="Heart rate, 1 min" icon={HeartbeatIcon}>
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
            { key: 'avg', label: 'Average', tone: 'hr', unit: 'bpm', area: true },
            { key: 'min', label: 'Minimum', tone: 'hr', unit: 'bpm', hidden: true },
            { key: 'max', label: 'Maximum', tone: 'hr', unit: 'bpm', hidden: true },
          ]}
        />
      </SectionCard>

      <SectionCard title="Stress" icon={GaugeIcon}>
        <TimeBarChart
          tz={tz}
          summary={stressSummary(bins.length, bins.filter((bin) => bin.band === 'high').length)}
          label="Stress"
          unit=""
          ticks={[0, 33, 67, 100]}
          rows={bins.map((bin) => ({ t: bin.t, value: bin.value, fill: bandFill(bin.band) }))}
        />
        <BandLegend />
      </SectionCard>

      <div className={live ? 'grid gap-6 md:grid-cols-2' : 'grid gap-6'}>
        <SectionCard title="Zones" icon={TargetIcon}>
          {zones ? (
            <ZoneBar rows={zones} legend />
          ) : (
            <EmptyState icon={TargetIcon} message={zoneGap(rhr !== null)} />
          )}
        </SectionCard>

        {live && (
          <SectionCard title="Last sync" icon={ArrowsClockwiseIcon}>
            <div className="flex flex-wrap items-center gap-3">
              <SyncStatusBadge lastBatchAt={lastBatch} now={now} />
              {lastBatch && (
                <p className="text-xs text-muted-foreground tabular-nums">Received {formatClock(Date.parse(lastBatch), tz)}</p>
              )}
            </div>
          </SectionCard>
        )}
      </div>
    </div>
  )
}

function DashboardSkeleton({ live }: { live: boolean }) {
  return (
    <div className="flex flex-col gap-6" aria-busy="true" aria-label="Loading">
      <div className={live ? 'grid grid-cols-2 gap-4 xl:grid-cols-5' : 'grid grid-cols-2 gap-4 xl:grid-cols-4'}>
        {Array.from({ length: live ? 5 : 4 }, (_, index) => (
          <Skeleton key={index} className="h-28" />
        ))}
      </div>
      <Skeleton className="h-72" />
      <Skeleton className="h-72" />
    </div>
  )
}

// The most recent non-null value in a window of days (oldest first).
function latestOf(days: DailySummary[], pick: (row: DailySummary) => number | null): { value: number; day: string } | null {
  for (const row of [...days].reverse()) {
    const value = pick(row)
    if (value !== null) return { value, day: row.day }
  }
  return null
}

function presentValues(series: (number | null)[]): number[] {
  return series.filter((value): value is number => value !== null)
}

// `rising` says whether a rise is good or bad for this metric (HRV rising is good, resting heart rate rising is not).
function deltaOf(change: number | null, unit: string, rising: 'good' | 'bad'): Delta | undefined {
  if (change === null) return undefined
  if (change === 0) return { text: `0 ${unit} vs 7 d`, direction: 'flat', meaning: 'neutral' }
  const up = change > 0
  return {
    text: `${up ? '+' : ''}${change} ${unit} vs 7 d`,
    direction: up ? 'up' : 'down',
    meaning: up === (rising === 'good') ? 'good' : 'bad',
  }
}

function zoneGap(hasRhr: boolean): string {
  if (!hasRhr) return 'Zones need a resting heart rate. It appears after the first night of data.'
  return 'Set HRmax or birth year in Settings to see zones.'
}

function hrSummary(points: HrPoint[]): string {
  const values = points.map((point) => point.avg)
  if (values.length === 0) return 'Heart rate: no samples'
  const low = Math.min(...values)
  const high = Math.max(...values)
  return `Heart rate, ${values.length} minutes, from ${Math.round(low)} to ${Math.round(high)} bpm`
}

function stressSummary(bins: number, high: number): string {
  if (bins === 0) return 'Stress: no values'
  return `Stress, ${bins} five-minute bins with a value, ${high} in the high band`
}

