import type { ReactNode } from 'react'

// One line of what is missing, and at most one action (PLAN.md §15.1 rule 7).
export function EmptyState({ message, action }: { message: string; action?: ReactNode }) {
  return (
    <div className="flex flex-col items-start gap-3">
      <p className="text-muted-foreground">{message}</p>
      {action}
    </div>
  )
}
