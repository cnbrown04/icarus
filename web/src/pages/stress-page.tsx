import { Button } from '@/components/ui/button'
import { Sheet, SheetClose, SheetContent, SheetDescription, SheetHeader, SheetTitle, SheetTrigger } from '@/components/ui/sheet'
import { BarSeriesChart, TimeSeriesChart } from '@/components/charts/series-chart'
import { EmptyState } from '@/components/empty-state'
import { ErrorLine } from '@/components/error-line'
import { LoadingBlock } from '@/components/loading'
import { Panel, Stat } from '@/components/stat'
import { describeError } from '@/lib/errors'
import { formatInt } from '@/lib/format'
import { HIGH_STRESS_FROM, stressBand } from '@/lib/health'
import { useDaily, useMe, useMinutes } from '@/lib/queries'
import { addDays, dayInZone, dayRange, formatDayShort, zonedMidnight } from '@/lib/time'
import { useNow } from '@/hooks/use-now'
import type { DailySummary, MinuteMetric } from '@/lib/types'

const BAND_LABEL = { low: 'Low', moderate: 'Moderate', high: 'High' } as const

export function StressPage() {
  const me = useMe()
  const now = useNow(60_000)
  if (me.isPending) return <LoadingBlock className="h-72" />
  if (me.isError) return <ErrorLine message={describeError(me.error)} />
  return <StressView tz={me.data.tz} now={now} />
}

function StressView({ tz, now }: { tz: string; now: Date }) {
  const today = dayInZone(now.getTime(), tz)
  const minutes = useMinutes(dayRange(today, tz, now))
  const daily = useDaily(addDays(today, -29), today)

  const error = [minutes, daily].find((query) => query.isError)
  if (error?.error) return <ErrorLine message={describeError(error.error)} />
  if (!minutes.data || !daily.data) return <LoadingBlock className="h-72" />

  const minuteRows = minutes.data.minutes
  const days = daily.data.days
  const withValue = minuteRows.filter((minute) => minute.stress !== null)
  if (minuteRows.length === 0 && days.every((row) => row.stress_avg === null)) {
    return <EmptyState message="No stress values yet" />
  }

  const latest = withValue.at(-1)
  const highToday = withValue.filter((minute) => (minute.stress ?? 0) >= HIGH_STRESS_FROM).length
  const todayRow = days.find((row) => row.day === today)
  const rmssdRows = days.filter((row): row is DailySummary & { rmssd_night_ms: number } => row.rmssd_night_ms !== null)
  const dailyRows = days.filter((row): row is DailySummary & { stress_avg: number } => row.stress_avg !== null)

  return (
    <div className="flex flex-col gap-6">
      <div className="grid gap-4 sm:grid-cols-3">
        <Panel title="Now" action={<StressInfo />}>
          <Stat
            label="Stress"
            value={latest?.stress ?? null}
            caption={latest?.stress != null ? BAND_LABEL[stressBand(latest.stress)] : undefined}
          />
        </Panel>
        <Panel title="High today">
          <Stat label="High-stress minutes" value={formatInt(highToday)} unit="min" />
        </Panel>
        <Panel title="Average today">
          <Stat
            label="Stress"
            value={todayRow?.stress_avg == null ? null : formatInt(todayRow.stress_avg)}
            unit="/ 100"
          />
        </Panel>
      </div>

      <Panel title="Timeline, today">
        {withValue.length === 0 ? (
          <EmptyState message="No stress values today" />
        ) : (
          <TimeSeriesChart
            tz={tz}
            summary={stressSummary(withValue)}
            domain={[0, 100]}
            ticks={[0, 33, 67, 100]}
            rows={minuteRows.map((minute: MinuteMetric) => ({ t: Date.parse(minute.minute), stress: minute.stress }))}
            series={[{ key: 'stress', label: 'Stress', tone: 'primary', unit: '' }]}
          />
        )}
      </Panel>

      <Panel title="Daily average, 30 days">
        {dailyRows.length === 0 ? (
          <EmptyState message="No daily averages yet" />
        ) : (
          <BarSeriesChart
            summary={`Daily stress average, ${dailyRows.length} days`}
            rows={dailyRows.map((row) => ({
              category: formatDayShort(row.day),
              day: row.day,
              stress: row.stress_avg,
            }))}
            series={[{ key: 'stress', label: 'Average stress', tone: 'primary', unit: '' }]}
            tickEvery={5}
            tooltipLabel={(row) => formatDayShort(row.day ?? '')}
          />
        )}
      </Panel>

      <Panel title="RMSSD, nights, 30 days">
        {rmssdRows.length === 0 ? (
          <EmptyState message="No overnight HRV yet" />
        ) : (
          <TimeSeriesChart
            tz={tz}
            summary={`Overnight RMSSD, ${rmssdRows.length} nights`}
            rows={rmssdRows.map((row) => ({ t: zonedMidnight(row.day, tz).getTime(), rmssd: row.rmssd_night_ms }))}
            series={[{ key: 'rmssd', label: 'RMSSD', tone: 'primary', unit: 'ms' }]}
          />
        )}
      </Panel>
    </div>
  )
}

function stressSummary(minutes: MinuteMetric[]): string {
  const high = minutes.filter((minute) => (minute.stress ?? 0) >= HIGH_STRESS_FROM).length
  return `Stress today, ${minutes.length} minutes with a value, ${high} in the high band`
}

// The method and its caveats, kept short (PLAN.md §8.3).
function StressInfo() {
  return (
    <Sheet>
      <SheetTrigger render={<Button variant="outline" size="sm" />}>How it works</SheetTrigger>
      <SheetContent>
        <SheetHeader>
          <SheetTitle>How stress is estimated</SheetTitle>
          <SheetDescription>Icarus stress is our own model. It is not WHOOP's Stress Monitor.</SheetDescription>
        </SheetHeader>
        <div className="flex flex-col gap-4 px-4 pb-4">
          <div className="flex flex-col gap-2">
            <p className="text-xs font-medium">Method</p>
            <p className="text-xs text-muted-foreground">
              Each 5-minute window compares heart rate and HRV (RMSSD) with your rolling 14-day baseline from
              night-time windows. The score runs from 0 to 100. 0 to 33 is low, 34 to 66 moderate, 67 and up high.
            </p>
            <p className="text-xs text-muted-foreground">A value needs about a week of data. Before that it shows calibrating.</p>
          </div>
          <div className="flex flex-col gap-2">
            <p className="text-xs font-medium">Caveats</p>
            <ul className="flex list-disc flex-col gap-2 pl-4 text-xs text-muted-foreground">
              <li>Optical heart-rate intervals are less accurate than ECG.</li>
              <li>Movement adds noise. Exercise is detected only from heart rate, so it is an approximation.</li>
              <li>Caffeine, alcohol, illness and posture all change HRV.</li>
              <li>Without heart-rate intervals, the value is heart-rate only and is labelled that way.</li>
            </ul>
          </div>
          <SheetClose render={<Button variant="outline" />}>Close</SheetClose>
        </div>
      </SheetContent>
    </Sheet>
  )
}
