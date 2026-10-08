import { ArrowDown, ArrowUp, Minus, type Icon } from '@phosphor-icons/react'
import type { ReactNode } from 'react'
import { Card, CardContent } from '@/components/ui/card'
import { cn } from '@/lib/utils'

export type Tone =
  | 'neutral'
  | 'hr'
  | 'hrv'
  | 'kcal-resting'
  | 'kcal-active'
  | 'stress-low'
  | 'stress-moderate'
  | 'stress-high'

// Tile icon square and icon colour. Stress tones also colour the value (the band word repeats it in text).
const TONE: Record<Tone, { icon: string; tile: string; value: string }> = {
  neutral: { icon: 'text-muted-foreground', tile: 'bg-muted', value: 'text-foreground' },
  hr: { icon: 'text-hr', tile: 'bg-hr-muted', value: 'text-foreground' },
  hrv: { icon: 'text-hrv', tile: 'bg-hrv-muted', value: 'text-foreground' },
  'kcal-resting': { icon: 'text-kcal-resting', tile: 'bg-kcal-resting-muted', value: 'text-foreground' },
  'kcal-active': { icon: 'text-kcal-active', tile: 'bg-kcal-active-muted', value: 'text-foreground' },
  'stress-low': { icon: 'text-stress-low', tile: 'bg-stress-low-muted', value: 'text-stress-low' },
  'stress-moderate': { icon: 'text-stress-moderate', tile: 'bg-stress-moderate-muted', value: 'text-stress-moderate' },
  'stress-high': { icon: 'text-stress-high', tile: 'bg-stress-high-muted', value: 'text-stress-high' },
}

// `meaning` picks the colour: a rise in resting heart rate is a warning, a rise in HRV is good.
export type Delta = { text: string; direction: 'up' | 'down' | 'flat'; meaning: 'good' | 'bad' | 'neutral' }

const DELTA_ICON = { up: ArrowUp, down: ArrowDown, flat: Minus } as const
const DELTA_TEXT = { good: 'text-status-ok', bad: 'text-status-warn', neutral: 'text-muted-foreground' } as const

// A value with its unit after it: "62 bpm" (PLAN.md §15.1 rule 5). Null shows a dash.
export function StatTile({
  icon: Icon,
  label,
  value,
  unit,
  tone = 'neutral',
  delta,
  sparkline,
  caption,
  className,
}: {
  icon: Icon
  label: string
  value: string | number | null
  unit?: string
  tone?: Tone
  delta?: Delta
  // Recent values, oldest first, drawn as a sparkline under the value. Missing values are left out.
  sparkline?: number[]
  caption?: ReactNode
  className?: string
}) {
  const style = TONE[tone]
  const DeltaIcon = delta ? DELTA_ICON[delta.direction] : null
  return (
    <Card className={className}>
      <CardContent className="flex flex-col gap-3">
        <div className="flex items-center gap-3">
          <span className={cn('flex size-8 shrink-0 items-center justify-center', style.tile)}>
            <Icon aria-hidden className={cn('size-4', style.icon)} />
          </span>
          <p className="min-w-0 text-xs text-muted-foreground">{label}</p>
        </div>
        <p className={cn('text-3xl font-medium tabular-nums', style.value)}>
          {value === null ? '—' : value}
          {unit && value !== null && (
            <>
              {' '}
              <span className="text-xs font-normal text-muted-foreground">{unit}</span>
            </>
          )}
        </p>
        {delta && DeltaIcon && (
          <p className={cn('flex items-center gap-1 text-xs tabular-nums', DELTA_TEXT[delta.meaning])}>
            <DeltaIcon aria-hidden className="size-3 shrink-0" />
            {delta.text}
          </p>
        )}
        {caption && <div className="text-xs text-muted-foreground">{caption}</div>}
        {sparkline && <Sparkline values={sparkline} className={style.icon} />}
      </CardContent>
    </Card>
  )
}

function Sparkline({ values, className }: { values: number[]; className: string }) {
  if (values.length < 2) return null
  const low = Math.min(...values)
  const high = Math.max(...values)
  // A flat series is drawn mid-height rather than on the baseline.
  const y = (value: number) => (high === low ? 12 : 24 - ((value - low) / (high - low)) * 24)
  const points = values.map((value, index) => `${(index / (values.length - 1)) * 100},${y(value)}`).join(' ')
  return (
    <svg aria-hidden viewBox="0 0 100 24" preserveAspectRatio="none" className={cn('h-8 w-full overflow-visible', className)}>
      <polyline
        points={points}
        fill="none"
        stroke="currentColor"
        strokeWidth={1.5}
        strokeLinejoin="round"
        vectorEffect="non-scaling-stroke"
      />
    </svg>
  )
}
