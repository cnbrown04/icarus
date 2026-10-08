import { ClockIcon, FlameIcon, LightningIcon, MoonIcon, SlidersIcon } from '@phosphor-icons/react'
import { Link } from '@tanstack/react-router'
import { BarSeriesChart } from '@/components/charts/series-chart'
import { EmptyState } from '@/components/empty-state'
import { ErrorLine } from '@/components/error-line'
import { LoadingBlock } from '@/components/loading'
import { SectionCard } from '@/components/section-card'
import { StatTile } from '@/components/stat-tile'
import { Button } from '@/components/ui/button'
import { useNow } from '@/hooks/use-now'
import { describeError } from '@/lib/errors'
import { formatInt } from '@/lib/format'
import { hourlyKcal } from '@/lib/health'
import { useDaily, useMe, useMinutes } from '@/lib/queries'
import { addDays, dayInZone, dayRange, formatDayShort, formatDayTitle, hourInZone } from '@/lib/time'
import type { DailySummary, Me } from '@/lib/types'

export function CaloriesPage() {
  const me = useMe()
  const now = useNow(60_000)
  if (me.isPending) return <LoadingBlock className="h-72" />
  if (me.isError) return <ErrorLine message={describeError(me.error)} />
  return <CaloriesView me={me.data} now={now} />
}

function CaloriesView({ me, now }: { me: Me; now: Date }) {
  const tz = me.tz
  const today = dayInZone(now.getTime(), tz)
  const daily = useDaily(addDays(today, -13), today)
  const minutes = useMinutes(dayRange(today, tz, now))

  const error = [daily, minutes].find((query) => query.isError)
  if (error?.error) return <ErrorLine message={describeError(error.error)} />
  if (!daily.data || !minutes.data) return <LoadingBlock className="h-72" />

  const days = daily.data.days
  const todayRow = days.find((row) => row.day === today)
  const hours = hourlyKcal(minutes.data.minutes, (minute) => hourInZone(Date.parse(minute), tz)).filter(
    (row) => row.hour <= hourInZone(now.getTime(), tz),
  )
  const hasDaily = days.some((row) => row.kcal_total !== null)

  if (!hasDaily && minutes.data.minutes.length === 0) {
    return (
      <EmptyState
        icon={FlameIcon}
        message="No calorie data yet"
        action={
          <Button variant="outline" render={<Link to="/devices" />}>
            Pair iPhone
          </Button>
        }
      />
    )
  }

  const resting = todayRow ? restingKcal(todayRow) : null

  return (
    <div className="flex flex-col gap-6">
      <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <StatTile
          icon={FlameIcon}
          label="Total"
          value={formatOrNull(todayRow?.kcal_total)}
          unit="kcal"
          caption={<span className="block">Estimated</span>}
        />
        <StatTile icon={MoonIcon} label="Resting" value={formatOrNull(resting)} unit="kcal" tone="kcal-resting" />
        <StatTile icon={LightningIcon} label="Active" value={formatOrNull(todayRow?.kcal_active)} unit="kcal" tone="kcal-active" />
        <SectionCard title="Profile used" icon={SlidersIcon}>
          <ProfileInputs me={me} />
        </SectionCard>
      </div>

      <SectionCard title="Resting and active, 14 days" icon={FlameIcon}>
        {hasDaily ? (
          <BarSeriesChart
            stacked
            summary={`Daily calories, resting and active, ${days.length} days`}
            rows={days.map((row) => ({
              category: formatDayShort(row.day),
              day: row.day,
              resting: restingKcal(row),
              active: row.kcal_active,
            }))}
            series={[
              { key: 'resting', label: 'Resting', tone: 'kcal-resting', unit: 'kcal' },
              { key: 'active', label: 'Active', tone: 'kcal-active', unit: 'kcal' },
            ]}
            tooltipLabel={(row) => formatDayTitle(row.day ?? '')}
          />
        ) : (
          <EmptyState icon={FlameIcon} message="No days with calories yet" />
        )}
      </SectionCard>

      <SectionCard title="Today by hour" icon={ClockIcon}>
        {minutes.data.minutes.length > 0 ? (
          <BarSeriesChart
            stacked
            tickEvery={3}
            summary={`Calories by hour today, ${hours.reduce((sum, row) => sum + row.kcal, 0).toFixed(0)} kcal`}
            rows={hours.map((row) => ({
              category: String(row.hour),
              day: today,
              resting: Math.max(0, row.kcal - row.active),
              active: row.active,
            }))}
            series={[
              { key: 'resting', label: 'Resting', tone: 'kcal-resting', unit: 'kcal' },
              { key: 'active', label: 'Active', tone: 'kcal-active', unit: 'kcal' },
            ]}
            tooltipLabel={(row) => `${String(row.category).padStart(2, '0')}:00`}
          />
        ) : (
          <EmptyState icon={ClockIcon} message="No minutes recorded today" />
        )}
      </SectionCard>
    </div>
  )
}

function restingKcal(row: DailySummary): number | null {
  if (row.kcal_total === null || row.kcal_active === null) return null
  return Math.max(0, row.kcal_total - row.kcal_active)
}

function formatOrNull(value: number | null | undefined): string | null {
  return value === null || value === undefined ? null : formatInt(value)
}

function ProfileInputs({ me }: { me: Me }) {
  const rows: [string, string][] = [
    ['Formula sex', me.formula_sex === null ? 'Not set' : me.formula_sex === 'male' ? 'Male' : 'Female'],
    ['Birth year', me.birth_year === null ? 'Not set' : String(me.birth_year)],
    ['Height', me.height_cm === null ? 'Not set' : `${me.height_cm} cm`],
    ['Weight', me.weight_kg === null ? 'Not set' : `${me.weight_kg} kg`],
  ]
  return (
    <div className="flex flex-col gap-4">
      <dl className="grid grid-cols-2 gap-x-4 gap-y-3 text-xs">
        {rows.map(([label, value]) => (
          <div key={label} className="flex flex-col gap-1">
            <dt className="text-muted-foreground">{label}</dt>
            <dd className="tabular-nums">{value}</dd>
          </div>
        ))}
      </dl>
      <Button variant="outline" className="self-start" render={<Link to="/settings" />}>
        Edit profile
      </Button>
    </div>
  )
}
