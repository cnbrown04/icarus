import type { ReactNode } from 'react'
import { Card, CardContent, CardHeader } from '@/components/ui/card'

// A single value with its unit after it: "62 bpm" (PLAN.md §15.1 rule 5).
export function Stat({
  label,
  value,
  unit,
  caption,
}: {
  label: string
  value: string | number | null
  unit?: string
  caption?: ReactNode
}) {
  const shown = value === null ? '—' : value
  return (
    <div className="flex flex-col gap-2">
      <p className="text-xs text-muted-foreground">{label}</p>
      <p className="text-3xl font-medium tabular-nums">
        {shown}
        {unit && value !== null && <span className="ml-1 text-xs font-normal text-muted-foreground">{unit}</span>}
      </p>
      {caption && <p className="text-xs text-muted-foreground">{caption}</p>}
    </div>
  )
}

// A grouped widget: one Card per meaningful group (PLAN.md §15.2 rule 15).
export function Panel({
  title,
  action,
  children,
  className,
}: {
  title: string
  action?: ReactNode
  children: ReactNode
  className?: string
}) {
  return (
    <Card className={className}>
      <CardHeader className="flex flex-row items-center justify-between gap-4">
        <h2 className="text-xs font-medium">{title}</h2>
        {action}
      </CardHeader>
      <CardContent className="flex flex-col gap-4">{children}</CardContent>
    </Card>
  )
}
