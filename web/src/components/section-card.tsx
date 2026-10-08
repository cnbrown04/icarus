import type { Icon } from '@phosphor-icons/react'
import type { ReactNode } from 'react'
import { Card, CardContent, CardHeader } from '@/components/ui/card'

// One card per meaningful group (PLAN.md §15.2 rule 15). The icon sits beside the title, never alone.
export function SectionCard({
  title,
  icon: Icon,
  action,
  children,
  className,
}: {
  title: string
  icon: Icon
  action?: ReactNode
  children: ReactNode
  className?: string
}) {
  return (
    <Card className={className}>
      <CardHeader className="flex flex-row items-center justify-between gap-4">
        <h2 className="flex min-w-0 items-center gap-2 text-xs font-medium">
          <Icon aria-hidden className="size-4 shrink-0 text-muted-foreground" />
          <span className="min-w-0">{title}</span>
        </h2>
        {action}
      </CardHeader>
      <CardContent className="flex flex-col gap-4">{children}</CardContent>
    </Card>
  )
}
