import type { HrZoneId, ZoneRow } from '@/lib/health'
import { cn } from '@/lib/utils'

export const ZONE_NAME: Record<HrZoneId, string> = {
  below: 'Below Z1',
  z1: 'Z1',
  z2: 'Z2',
  z3: 'Z3',
  z4: 'Z4',
  z5: 'Z5',
}

// Below Z1 is neutral: it is not a training zone, so it does not get a zone colour.
export const ZONE_FILL: Record<HrZoneId, string> = {
  below: 'bg-muted-foreground/40',
  z1: 'bg-zone-1',
  z2: 'bg-zone-2',
  z3: 'bg-zone-3',
  z4: 'bg-zone-4',
  z5: 'bg-zone-5',
}

// Minutes per zone as one stacked bar, in zone order. The table or legend beside it carries the numbers.
export function ZoneBar({ rows, legend = false }: { rows: ZoneRow[]; legend?: boolean }) {
  const total = rows.reduce((sum, row) => sum + row.minutes, 0)
  const used = rows.filter((row) => row.minutes > 0)
  const summary = `Zones, ${total} minutes: ${used.map((row) => `${ZONE_NAME[row.id]} ${row.minutes} min`).join(', ') || 'none'}`
  return (
    <div className="flex flex-col gap-3">
      <div role="img" aria-label={summary} className="flex h-4 w-full overflow-hidden">
        {used.map((row) => (
          <span key={row.id} className={ZONE_FILL[row.id]} style={{ width: `${(row.minutes / total) * 100}%` }} />
        ))}
      </div>
      {legend && (
        <ul className="flex flex-wrap gap-4 text-xs">
          {rows.map((row) => (
            <li key={row.id} className="flex items-center gap-2 whitespace-nowrap">
              <span aria-hidden className={cn('size-3 shrink-0', ZONE_FILL[row.id])} />
              {ZONE_NAME[row.id]}
              <span className="text-muted-foreground tabular-nums">{Math.round(row.minutes)} min</span>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
