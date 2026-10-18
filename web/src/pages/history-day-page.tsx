import { CalendarBlankIcon } from '@phosphor-icons/react'
import { Link, useParams } from '@tanstack/react-router'
import { DayDashboard } from '@/components/day-dashboard'
import { EmptyState } from '@/components/empty-state'
import { ErrorLine } from '@/components/error-line'
import { LoadingBlock } from '@/components/loading'
import { Button } from '@/components/ui/button'
import { describeError } from '@/lib/errors'
import { useMe } from '@/lib/queries'
import { isDay } from '@/lib/time'

export function HistoryDayPage() {
  const { day = '' } = useParams({ strict: false })
  const me = useMe()
  if (!isDay(day)) return <EmptyState icon={CalendarBlankIcon} message="Nothing at this address." />
  if (me.isPending) return <LoadingBlock className="h-72" />
  if (me.isError) return <ErrorLine message={describeError(me.error)} />

  return (
    <DayDashboard
      day={day}
      tz={me.data.tz}
      live={false}
      emptyIcon={CalendarBlankIcon}
      emptyMessage="No data for this day"
      emptyAction={
        <Button variant="outline" render={<Link to="/history" />}>
          Back to History
        </Button>
      }
    />
  )
}
