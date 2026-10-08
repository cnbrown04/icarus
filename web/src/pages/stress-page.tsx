import { CalendarBlankIcon, ChartLineIcon, GaugeIcon, InfoIcon, WarningIcon, WaveformIcon } from '@phosphor-icons/react'
import { BarSeriesChart, TimeBarChart, TimeSeriesChart } from '@/components/charts/series-chart'
import { BandLegend, MetricBand, bandFill, bandTone } from '@/components/metric-band'
import { EmptyState } from '@/components/empty-state'
import { ErrorLine } from '@/components/error-line'
import { LoadingBlock } from '@/components/loading'
import { SectionCard } from '@/components/section-card'
import { StatTile } from '@/components/stat-tile'
import { Button } from '@/components/ui/button'
import { Sheet, SheetClose, SheetContent, SheetDescription, SheetHeader, SheetTitle, SheetTrigger } from '@/components/ui/sheet'
import { useNow } from '@/hooks/use-now'
import { describeError } from '@/lib/errors'
import { formatInt } from '@/lib/format'
import { binStress, HIGH_STRESS_FROM, stressBand } from '@/lib/health'
import { useDaily, useMe, useMinutes } from '@/lib/queries'
import { addDays, dayInZone, dayRange, formatDayShort, zonedMidnight } from '@/lib/time'
import type { DailySummary } from '@/lib/types'

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
    return <EmptyState icon={WaveformIcon} message="No stress values yet" />
  }

  const latest = withValue.at(-1)
  const latestBand = latest?.stress == null ? null : stressBand(Math.round(latest.stress))
  const highToday = withValue.filter((minute) => (minute.stress ?? 0) >= HIGH_STRESS_FROM).length
  const todayRow = days.find((row) => row.day === today)
  const rmssdRows = days.filter((row): row is DailySummary & { rmssd_night_ms: number } => row.rmssd_night_ms !== null)
  const dailyRows = days.filter((row): row is DailySummary & { stress_avg: number } => row.stress_avg !== null)
  const bins = binStress(minuteRows)

  return (
    <div className="flex flex-col gap-6">
      <div className="grid gap-4 sm:grid-cols-3">
        <StatTile
          icon={GaugeIcon}
          label="Stress now"
          value={latest?.stress == null ? null : formatInt(latest.stress)}
          unit="/ 100"
          tone={latestBand ? bandTone(latestBand) : 'neutral'}
          caption={latestBand ? <MetricBand band={latestBand} showRange /> : undefined}
        />
        <StatTile icon={WarningIcon} label="High-stress minutes" value={formatInt(highToday)} unit="min" tone="stress-high" />
        <StatTile
          icon={ChartLineIcon}
          label="Average today"
          value={todayRow?.stress_avg == null ? null : formatInt(todayRow.stress_avg)}
          unit="/ 100"
        />
      </div>

      <SectionCard title="Timeline, today" icon={GaugeIcon} action={<StressInfo />}>
        {withValue.length === 0 ? (
          <EmptyState icon={GaugeIcon} message="No stress values today" />
        ) : (
          <>
            <TimeBarChart
              tz={tz}
              summary={stressSummary(bins.length, highToday)}
              label="Stress"
              unit=""
              domain={[0, 100]}
              ticks={[0, 33, 67, 100]}
              rows={bins.map((bin) => ({ t: bin.t, value: bin.value, fill: bandFill(bin.band) }))}
            />
            <BandLegend />
          </>
        )}
      </SectionCard>

      <SectionCard title="Daily average, 30 days" icon={CalendarBlankIcon}>
        {dailyRows.length === 0 ? (
          <EmptyState icon={CalendarBlankIcon} message="No daily averages yet" />
        ) : (
          <>
            <BarSeriesChart
              summary={`Daily stress average, ${dailyRows.length} days`}
              rows={dailyRows.map((row) => ({
                category: formatDayShort(row.day),
                day: row.day,
                stress: row.stress_avg,
              }))}
              series={[{ key: 'stress', label: 'Average stress', tone: 'primary', unit: '' }]}
              fillOf={(row) => bandFill(stressBand(Math.round(Number(row.stress))))}
              tickEvery={5}
              tooltipLabel={(row) => formatDayShort(row.day ?? '')}
            />
            <BandLegend />
          </>
        )}
      </SectionCard>

      <SectionCard title="RMSSD, nights, 30 days" icon={WaveformIcon}>
        {rmssdRows.length === 0 ? (
          <EmptyState icon={WaveformIcon} message="No overnight HRV yet" />
        ) : (
          <TimeSeriesChart
            tz={tz}
            summary={`Overnight RMSSD, ${rmssdRows.length} nights`}
            rows={rmssdRows.map((row) => ({ t: zonedMidnight(row.day, tz).getTime(), rmssd: row.rmssd_night_ms }))}
            series={[{ key: 'rmssd', label: 'RMSSD', tone: 'hrv', unit: 'ms' }]}
          />
        )}
      </SectionCard>
    </div>
  )
}

function stressSummary(bins: number, high: number): string {
  return `Stress today, ${bins} five-minute bins with a value, ${high} minutes in the high band`
}

// The method and its caveats, kept short (PLAN.md §8.3).
function StressInfo() {
  return (
    <Sheet>
      <SheetTrigger render={<Button variant="outline" size="sm" />}>
        <InfoIcon aria-hidden />
        How it works
      </SheetTrigger>
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

