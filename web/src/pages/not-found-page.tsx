import { CompassIcon } from '@phosphor-icons/react'
import { Link } from '@tanstack/react-router'
import { EmptyState } from '@/components/empty-state'
import { Button } from '@/components/ui/button'

export function NotFoundPage() {
  return (
    <EmptyState
      icon={CompassIcon}
      message="Nothing at this address."
      action={
        <Button variant="outline" render={<Link to="/" />}>
          Go to Today
        </Button>
      }
    />
  )
}
