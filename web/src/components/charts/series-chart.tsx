import type { ReactNode } from 'react'
import { Bar, BarChart, CartesianGrid, Line, LineChart, XAxis, YAxis } from 'recharts'
import {
  ChartContainer,
  ChartLegend,
  ChartLegendContent,
  ChartTooltip,
  ChartTooltipContent,
  type ChartConfig,
} from '@/components/ui/chart'
import { formatClock, formatDateTime } from '@/lib/time'

// Chart colours come from Lyra's chart tokens only (PLAN.md §15.3 rule 18). Light uses the dark end of the
// ramp and dark uses the light end, so a single series keeps its contrast in both themes.
const TONE = {
  primary: { light: 'var(--chart-5)', dark: 'var(--chart-1)' },
  secondary: { light: 'var(--chart-3)', dark: 'var(--chart-3)' },
} as const

export type SeriesTone = keyof typeof TONE

export type Series = {
  key: string
  label: string
  tone: SeriesTone
  // Listed in the tooltip but not drawn (e.g. the min and max behind an average).
  hidden?: boolean
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
  return (
    <Frame summary={summary}>
      <ChartContainer config={config} className={`${height} aspect-auto`}>
        <LineChart data={rows} margin={{ top: 8, right: 8, bottom: 0, left: 0 }}>
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
          {series.map((s) => (
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
          ))}
        </LineChart>
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
  tickEvery = 1,
  height = 'h-64',
}: {
  rows: BarRow[]
  series: Series[]
  summary: string
  stacked?: boolean
  tooltipLabel: (row: BarRow) => string
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
          {series.map((s) => (
            <Bar
              key={s.key}
              dataKey={s.key}
              name={s.label}
              fill={`var(--color-${s.key})`}
              radius={0}
              isAnimationActive={false}
              stackId={stacked ? 'stack' : undefined}
            />
          ))}
          {/* A legend only when there is more than one series (PLAN.md §15.3 rule 21). */}
          {series.length > 1 && <ChartLegend content={<ChartLegendContent />} />}
        </BarChart>
      </ChartContainer>
    </Frame>
  )
}
