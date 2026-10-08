import { Link, useParams } from '@tanstack/react-router'
import { DayDashboard } from '@/components/day-dashboard'
import { ErrorLine } from '@/components/error-line'
import { LoadingBlock } from '@/components/loading'
import { Button } from '@/components/ui/button'
import { describeError } from '@/lib/errors'
import { useMe } from '@/lib/queries'
import { isDay } from '@/lib/time'

export function HistoryDayPage() {
  const { day = '' } = useParams({ strict: false })
  const me = useMe()
  if (!isDay(day)) return <p className="text-muted-foreground">Nothing at this address.</p>
  if (me.isPending) return <LoadingBlock className="h-72" />
  if (me.isError) return <ErrorLine message={describeError(me.error)} />

  return (
    <DayDashboard
      day={day}
      tz={me.data.tz}
      live={false}
      emptyMessage="No data for this day"
      emptyAction={
        <Button variant="outline" render={<Link to="/history" />}>
          Back to History
        </Button>
      }
    />
  )
}
