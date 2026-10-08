import { useId, type ReactNode } from 'react'
import { Area, Bar, BarChart, Cell, CartesianGrid, ComposedChart, Line, XAxis, YAxis } from 'recharts'
import {
  ChartContainer,
  ChartLegend,
  ChartLegendContent,
  ChartTooltip,
  ChartTooltipContent,
  type ChartConfig,
} from '@/components/ui/chart'
import { formatClock, formatDateTime } from '@/lib/time'

// Neutral series use Lyra's chart tokens (PLAN.md §15.3 rule 18). Heart rate, HRV and kcal use the app's semantic
// tokens (web/src/styles/semantic.css). Each tone is the same in both themes, so the variables do the switching.
const TONE = {
  primary: { light: 'var(--chart-5)', dark: 'var(--chart-1)' },
  secondary: { light: 'var(--chart-3)', dark: 'var(--chart-3)' },
  hr: { light: 'var(--hr)', dark: 'var(--hr)' },
  hrv: { light: 'var(--hrv)', dark: 'var(--hrv)' },
  'kcal-resting': { light: 'var(--kcal-resting)', dark: 'var(--kcal-resting)' },
  'kcal-active': { light: 'var(--kcal-active)', dark: 'var(--kcal-active)' },
} as const

export type SeriesTone = keyof typeof TONE

export type Series = {
  key: string
  label: string
  tone: SeriesTone
  // Listed in the tooltip but not drawn (e.g. the min and max behind an average).
  hidden?: boolean
  // Fill under the line, with an opacity gradient. Used for the heart-rate series only.
  area?: boolean
  unit: string
}

function configFor(series: Series[]): ChartConfig {
  return Object.fromEntries(series.map((s) => [s.key, { label: s.label, theme: TONE[s.tone] }]))
}

// Chart frame: the summary is the accessible name of the chart, read by screen readers (PLAN.md §14).
function Frame({ summary, children }: { summary: string; children: ReactNode }) {
  return (
    <div role="img" aria-label={summary} className="w-full">
      {children}
    </div>
  )
}

type TimeRow = { t: number } & Record<string, number | null>

export function TimeSeriesChart({
  rows,
  series,
  tz,
  summary,
  domain = ['auto', 'auto'],
  ticks,
  height = 'h-64',
}: {
  rows: TimeRow[]
  series: Series[]
  tz: string
  summary: string
  domain?: [number | 'auto' | 'dataMin' | 'dataMax', number | 'auto' | 'dataMin' | 'dataMax']
  // Explicit guides (at most four, PLAN.md §15.3 rule 21), for example the stress band edges.
  ticks?: number[]
  height?: string
}) {
  const config = configFor(series)
  // useId has colons, which are awkward in url(#id), so they are stripped.
  const gradientPrefix = useId().replace(/[^a-zA-Z0-9]/g, '')
  return (
    <Frame summary={summary}>
      <ChartContainer config={config} className={`${height} aspect-auto`}>
        <ComposedChart data={rows} margin={{ top: 8, right: 8, bottom: 0, left: 0 }}>
          <defs>
            {series
              .filter((s) => s.area)
              .map((s) => (
                <linearGradient key={s.key} id={`${gradientPrefix}-${s.key}`} x1="0" x2="0" y1="0" y2="1">
                  <stop offset="0%" stopOpacity={0.25} style={{ stopColor: `var(--color-${s.key})` }} />
                  <stop offset="100%" stopOpacity={0} style={{ stopColor: `var(--color-${s.key})` }} />
                </linearGradient>
              ))}
          </defs>
          <CartesianGrid vertical={false} />
          <XAxis
            dataKey="t"
            type="number"
            domain={['dataMin', 'dataMax']}
            tickFormatter={(value: number) => formatClock(value, tz)}
            tickLine={false}
            axisLine={false}
            tickMargin={8}
            minTickGap={32}
          />
          <YAxis
            tickCount={4}
            ticks={ticks}
            domain={domain}
            tickLine={false}
            axisLine={false}
            width={40}
            allowDecimals={false}
          />
          <ChartTooltip
            cursor={{ stroke: 'var(--border)' }}
            content={
              <ChartTooltipContent
                labelFormatter={(_, payload) => {
                  const row = payload?.[0]?.payload as TimeRow | undefined
                  return row ? formatDateTime(row.t, tz) : ''
                }}
                formatter={(value, _name, item) => {
                  const entry = series.find((s) => s.key === item.dataKey)
                  return value === null || value === undefined ? '—' : `${value} ${entry?.unit ?? ''}`
                }}
              />
            }
          />
          {series.map((s) =>
            s.area ? (
              <Area
                key={s.key}
                dataKey={s.key}
                name={s.label}
                type="linear"
                stroke={`var(--color-${s.key})`}
                strokeWidth={1.5}
                fill={`url(#${gradientPrefix}-${s.key})`}
                dot={false}
                activeDot={{ r: 3 }}
                connectNulls={false}
                isAnimationActive={false}
              />
            ) : (
              <Line
                key={s.key}
                dataKey={s.key}
                name={s.label}
                type="linear"
                stroke={s.hidden ? 'none' : `var(--color-${s.key})`}
                strokeWidth={1.5}
                dot={false}
                activeDot={s.hidden ? false : { r: 3 }}
                connectNulls={false}
                isAnimationActive={false}
              />
            ),
          )}
        </ComposedChart>
      </ChartContainer>
    </Frame>
  )
}

export type TimeBarRow = { t: number; value: number | null; fill: string }

// One bar per time bucket, each filled by its own colour (stress bands). Rows arrive already bucketed.
export function TimeBarChart({
  rows,
  tz,
  summary,
  label,
  unit,
  domain = [0, 100],
  ticks,
  height = 'h-64',
}: {
  rows: TimeBarRow[]
  tz: string
  summary: string
  label: string
  unit: string
  domain?: [number, number]
  ticks?: number[]
  height?: string
}) {
  const config: ChartConfig = { value: { label, theme: TONE.primary } }
  return (
    <Frame summary={summary}>
      <ChartContainer config={config} className={`${height} aspect-auto`}>
        <BarChart data={rows} margin={{ top: 8, right: 8, bottom: 0, left: 0 }}>
          <CartesianGrid vertical={false} />
          <XAxis
            dataKey="t"
            tickFormatter={(value: number) => formatClock(value, tz)}
            tickLine={false}
            axisLine={false}
            tickMargin={8}
            minTickGap={32}
            interval="preserveStartEnd"
          />
          <YAxis
            tickCount={4}
            ticks={ticks}
            domain={domain}
            tickLine={false}
            axisLine={false}
            width={40}
            allowDecimals={false}
          />
          <ChartTooltip
            cursor={{ fill: 'var(--muted)' }}
            content={
              <ChartTooltipContent
                labelFormatter={(_, payload) => {
                  const row = payload?.[0]?.payload as TimeBarRow | undefined
                  return row ? formatDateTime(row.t, tz) : ''
                }}
                formatter={(value) => (value === null || value === undefined ? '—' : `${value} ${unit}`)}
              />
            }
          />
          <Bar dataKey="value" name={label} radius={0} isAnimationActive={false}>
            {rows.map((row) => (
              <Cell key={row.t} fill={row.fill} />
            ))}
          </Bar>
        </BarChart>
      </ChartContainer>
    </Frame>
  )
}

type BarRow = { category: string; day?: string } & Record<string, number | string | null | undefined>

export function BarSeriesChart({
  rows,
  series,
  summary,
  stacked = false,
  tooltipLabel,
  fillOf,
  tickEvery = 1,
  height = 'h-64',
}: {
  rows: BarRow[]
  series: Series[]
  summary: string
  stacked?: boolean
  tooltipLabel: (row: BarRow) => string
  // Colours each bar of the first series by its own row, for example the stress band of a daily average.
  fillOf?: (row: BarRow) => string
  // Label every nth category, for dense axes such as 24 hours on a phone.
  tickEvery?: number
  height?: string
}) {
  const config = configFor(series)
  return (
    <Frame summary={summary}>
      <ChartContainer config={config} className={`${height} aspect-auto`}>
        <BarChart data={rows} margin={{ top: 8, right: 8, bottom: 0, left: 0 }}>
          <CartesianGrid vertical={false} />
          <XAxis
            dataKey="category"
            tickLine={false}
            axisLine={false}
            tickMargin={8}
            interval={tickEvery - 1}
            minTickGap={8}
          />
          <YAxis tickCount={4} tickLine={false} axisLine={false} width={40} allowDecimals={false} />
          <ChartTooltip
            cursor={{ fill: 'var(--muted)' }}
            content={
              <ChartTooltipContent
                labelFormatter={(_, payload) => {
                  const row = payload?.[0]?.payload as BarRow | undefined
                  return row ? tooltipLabel(row) : ''
                }}
                formatter={(value, _name, item) => {
                  const entry = series.find((s) => s.key === item.dataKey)
                  return `${value ?? '—'} ${entry?.unit ?? ''}`
                }}
              />
            }
          />
          {series.map((s, index) => (
            <Bar
              key={s.key}
              dataKey={s.key}
              name={s.label}
              fill={`var(--color-${s.key})`}
              radius={0}
              isAnimationActive={false}
              stackId={stacked ? 'stack' : undefined}
            >
              {index === 0 && fillOf && rows.map((row, i) => <Cell key={i} fill={fillOf(row)} />)}
            </Bar>
          ))}
          {/* A legend only when there is more than one series (PLAN.md §15.3 rule 21). */}
          {series.length > 1 && <ChartLegend content={<ChartLegendContent />} />}
        </BarChart>
      </ChartContainer>
    </Frame>
  )
}
