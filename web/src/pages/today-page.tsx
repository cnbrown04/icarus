import { Link } from '@tanstack/react-router'
import { DayDashboard } from '@/components/day-dashboard'
import { ErrorLine } from '@/components/error-line'
import { LoadingBlock } from '@/components/loading'
import { Button } from '@/components/ui/button'
import { useNow } from '@/hooks/use-now'
import { describeError } from '@/lib/errors'
import { useMe } from '@/lib/queries'
import { dayInZone } from '@/lib/time'

export function TodayPage() {
  const me = useMe()
  const now = useNow(60_000)
  if (me.isPending) return <LoadingBlock className="h-72" />
  if (me.isError) return <ErrorLine message={describeError(me.error)} />

  return (
    <DayDashboard
      day={dayInZone(now.getTime(), me.data.tz)}
      tz={me.data.tz}
      live
      emptyMessage="No data yet"
      emptyAction={
        <Button variant="outline" render={<Link to="/devices" />}>
          Pair iPhone
        </Button>
      }
    />
  )
}

