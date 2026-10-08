import type { Icon } from '@phosphor-icons/react'
import type { ReactNode } from 'react'

// One line of what is missing, and at most one action (PLAN.md §15.1 rule 7). The icon is large and muted.
export function EmptyState({ icon: Icon, message, action }: { icon: Icon; message: string; action?: ReactNode }) {
  return (
    <div className="flex flex-col items-start gap-3 py-8">
      <Icon aria-hidden className="size-8 text-muted-foreground" />
      <p className="text-muted-foreground">{message}</p>
      {action}
    </div>
  )
}
