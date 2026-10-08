import type { StressBand } from '@/lib/health'
import { cn } from '@/lib/utils'

// Stress bands as the app names them (PLAN.md §8.3, and the stress sheet copy).
const BAND: Record<StressBand, { label: string; range: string; swatch: string; fill: string }> = {
  low: { label: 'Low', range: '0 to 33', swatch: 'bg-stress-low', fill: 'var(--stress-low)' },
  moderate: { label: 'Moderate', range: '34 to 66', swatch: 'bg-stress-moderate', fill: 'var(--stress-moderate)' },
  high: { label: 'High', range: '67 and up', swatch: 'bg-stress-high', fill: 'var(--stress-high)' },
}

export const BANDS: StressBand[] = ['low', 'moderate', 'high']

export function bandFill(band: StressBand): string {
  return BAND[band].fill
}

export function bandTone(band: StressBand): 'stress-low' | 'stress-moderate' | 'stress-high' {
  return `stress-${band}`
}

export function bandLabel(band: StressBand): string {
  return BAND[band].label
}

// A stress band as a swatch and its word, with the range when asked for.
export function MetricBand({ band, showRange = false }: { band: StressBand; showRange?: boolean }) {
  const entry = BAND[band]
  return (
    <span className="inline-flex items-center gap-2 text-xs whitespace-nowrap">
      <span aria-hidden className={cn('size-3 shrink-0', entry.swatch)} />
      {entry.label}
      {showRange && <span className="text-muted-foreground">{entry.range}</span>}
    </span>
  )
}

// The three bands as a legend for multi-band charts.
export function BandLegend() {
  return (
    <ul className="flex flex-wrap gap-4">
      {BANDS.map((band) => (
        <li key={band}>
          <MetricBand band={band} showRange />
        </li>
      ))}
    </ul>
  )
}
