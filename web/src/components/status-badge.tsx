import { CheckCircle, Info, MinusCircle, Warning, XCircle, type Icon } from '@phosphor-icons/react'
import type { ReactNode } from 'react'
import { cn } from '@/lib/utils'

export type StatusVariant = 'ok' | 'warn' | 'danger' | 'info' | 'neutral'

const VARIANT: Record<StatusVariant, { icon: Icon; className: string }> = {
  ok: { icon: CheckCircle, className: 'bg-status-ok-muted text-status-ok' },
  warn: { icon: Warning, className: 'bg-status-warn-muted text-status-warn' },
  danger: { icon: XCircle, className: 'bg-status-danger-muted text-status-danger' },
  info: { icon: Info, className: 'bg-status-info-muted text-status-info' },
  neutral: { icon: MinusCircle, className: 'border text-muted-foreground' },
}

// Colour never carries a status alone: the icon and the words say it too (PLAN.md §15.3 rule 18).
export function StatusBadge({ variant, children }: { variant: StatusVariant; children: ReactNode }) {
  const { icon: Icon, className } = VARIANT[variant]
  return (
    <span className={cn('inline-flex w-fit max-w-full items-center gap-1 px-2 py-1 text-xs', className)}>
      <Icon aria-hidden className="size-3 shrink-0" />
      {children}
    </span>
  )
}
