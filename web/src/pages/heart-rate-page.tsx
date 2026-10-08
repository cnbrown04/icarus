import { useState } from 'react'
import { TimeSeriesChart } from '@/components/charts/series-chart'
import { EmptyState } from '@/components/empty-state'
import { ErrorLine } from '@/components/error-line'
import { LoadingBlock } from '@/components/loading'
import { Panel, Stat } from '@/components/stat'
import { Segmented } from '@/components/segmented'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { useNow } from '@/hooks/use-now'
import { describeError } from '@/lib/errors'
import { formatInt } from '@/lib/format'
import { useDaily, useHr, useMe } from '@/lib/queries'
import { resolveHrMax, zoneDistribution, type ZoneRow } from '@/lib/health'
import { addDays, dayInZone, zonedMidnight } from '@/lib/time'
import type { DailySummary, HrPoint, HrResolution, Me } from '@/lib/types'

type RangeKey = '6h' | '24h' | '7d' | '30d'

// Resolution per PLAN.md §10.4: raw up to 6 h, minute or 5-minute aggregates up to 14 d, daily beyond that.
// `res` is null for the daily range, which reads /metrics/daily instead of /metrics/hr.
const RANGES: { value: RangeKey; label: string; hours: number; res: HrResolution | null }[] = [
  { value: '6h', label: '6 h', hours: 6, res: 'raw' },
  { value: '24h', label: '24 h', hours: 24, res: '1m' },
  { value: '7d', label: '7 d', hours: 24 * 7, res: '5m' },
  { value: '30d', label: '30 d', hours: 24 * 30, res: null },
]

export function HeartRatePage() {
  const me = useMe()
  const [range, setRange] = useState<RangeKey>('24h')
  const now = useNow(60_000)
  if (me.isPending) return <LoadingBlock className="h-72" />
  if (me.isError) return <ErrorLine message={describeError(me.error)} />
  return <HeartRateView me={me.data} range={range} onRange={setRange} now={now} />
}

function HeartRateView({
  me,
  range,
  onRange,
  now,
}: {
  me: Me
  range: RangeKey
  onRange: (range: RangeKey) => void
  now: Date
}) {
  const config = RANGES.find((item) => item.value === range) ?? RANGES[1]
  const isDaily = config.res === null
  const span = { from: new Date(now.getTime() - config.hours * 3_600_000), to: now }
  const hr = useHr(span, config.res ?? '1m', !isDaily)
  // One 30-day daily query serves the daily range and the resting heart rate trend.
  const today = dayInZone(now.getTime(), me.tz)
  const daily = useDaily(addDays(today, -29), today)

  const tz = me.tz
  const trendRows = rhrRows(daily.data?.days ?? [])
  const dailyRows = isDaily ? (daily.data?.days ?? []) : []
  const points: HrPoint[] = hr.data?.points ?? []
  const rhr = trendRows.at(-1)

  const error = [hr, daily].find((query) => query.isError)
  if (error?.error) return <ErrorLine message={describeError(error.error)} />
  const loading = (!isDaily && hr.isPending) || daily.isPending
  if (loading) return <LoadingBlock className="h-72" />

  const summary = isDaily ? summariseDaily(dailyRows) : summarisePoints(points)
  const hasData = isDaily ? dailyRows.length > 0 : points.length > 0

  return (
    <div className="flex flex-col gap-6">
      <Segmented
        label="Range"
        options={RANGES.map(({ value, label }) => ({ value, label }))}
        value={range}
        onChange={onRange}
      />

      {!hasData ? (
        <EmptyState message="No heart rate in this range" />
      ) : (
        <>
          <div className="grid grid-cols-3 gap-4">
            <Stat label="Average" value={summary.avg === null ? null : formatInt(summary.avg)} unit="bpm" />
            <Stat label="Minimum" value={summary.min === null ? null : formatInt(summary.min)} unit="bpm" />
            <Stat label="Maximum" value={summary.max === null ? null : formatInt(summary.max)} unit="bpm" />
          </div>

          <Panel title="Heart rate">
            {isDaily ? (
              <TimeSeriesChart
                tz={tz}
                summary={`Average heart rate by day, ${dailyRows.length} days`}
                rows={dailyRows.map((row) => ({
                  t: zonedMidnight(row.day, tz).getTime(),
                  avg: row.hr_avg,
                  max: row.hr_max,
                }))}
                series={[
                  { key: 'avg', label: 'Daily average', tone: 'primary', unit: 'bpm' },
                  { key: 'max', label: 'Daily maximum', tone: 'secondary', unit: 'bpm', hidden: true },
                ]}
              />
            ) : (
              <TimeSeriesChart
                tz={tz}
                summary={`Heart rate, ${points.length} samples, ${summary.min} to ${summary.max} bpm`}
                rows={points.map((point) => ({
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
            )}
          </Panel>

          <ZonesPanel me={me} now={now} rhr={rhr?.rhr ?? null} points={points} isDaily={isDaily} />
        </>
      )}

      <Panel title="Resting heart rate, 30 days">
        {trendRows.length > 0 ? (
          <TimeSeriesChart
            tz={tz}
            summary="Resting heart rate by night, last 30 days"
            rows={trendRows.map((row) => ({ t: zonedMidnight(row.day, tz).getTime(), rhr: row.rhr }))}
            series={[{ key: 'rhr', label: 'Resting heart rate', tone: 'primary', unit: 'bpm' }]}
          />
        ) : (
          <EmptyState message="No resting heart rate yet" />
        )}
      </Panel>
    </div>
  )
}

function ZonesPanel({
  me,
  now,
  rhr,
  points,
  isDaily,
}: {
  me: Me
  now: Date
  rhr: number | null
  points: HrPoint[]
  isDaily: boolean
}) {
  const hrMax = resolveHrMax(me, now)
  if (isDaily) {
    return (
      <Panel title="Zones">
        <p className="text-muted-foreground">Zones need minute data. Choose 7 d or less.</p>
      </Panel>
    )
  }
  if (hrMax === null) {
    return (
      <Panel title="Zones">
        <p className="text-muted-foreground">Set HRmax or birth year in Settings to see zones.</p>
      </Panel>
    )
  }
  if (rhr === null) {
    return (
      <Panel title="Zones">
        <p className="text-muted-foreground">Zones need a resting heart rate. It appears after the first night of data.</p>
      </Panel>
    )
  }
  const rows: ZoneRow[] = zoneDistribution(
    points.map((point) => point.avg),
    rhr,
    hrMax.value,
  )
  return (
    <Panel
      title="Zones"
      action={
        <p className="text-xs text-muted-foreground">
          {hrMax.source === 'entered' ? `HRmax ${hrMax.value} bpm` : `HRmax ${hrMax.value} bpm, estimated from age`}
        </p>
      }
    >
      <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Zone, % of reserve</TableHead>
              <TableHead className="text-right">Minutes</TableHead>
              <TableHead className="text-right">Share</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((row) => (
              <TableRow key={row.id}>
                <TableCell>{row.label}</TableCell>
                <TableCell className="text-right tabular-nums">{formatInt(row.minutes)}</TableCell>
                <TableCell className="text-right tabular-nums">{formatInt(row.share * 100)} %</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
    </Panel>
  )
}

function rhrRows(days: DailySummary[]) {
  return days.filter((row): row is DailySummary & { rhr: number } => row.rhr !== null)
}

function summarisePoints(points: HrPoint[]) {
  if (points.length === 0) return { avg: null, min: null, max: null }
  const avg = points.reduce((sum, point) => sum + point.avg, 0) / points.length
  return {
    avg,
    min: Math.min(...points.map((point) => point.min)),
    max: Math.max(...points.map((point) => point.max)),
  }
}

function summariseDaily(days: DailySummary[]) {
  const withAvg = days.filter((row): row is DailySummary & { hr_avg: number } => row.hr_avg !== null)
  if (withAvg.length === 0) return { avg: null, min: null, max: null }
  return {
    avg: withAvg.reduce((sum, row) => sum + row.hr_avg, 0) / withAvg.length,
    min: null,
    max: Math.max(...withAvg.map((row) => row.hr_max ?? row.hr_avg)),
  }
}
