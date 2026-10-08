import { ErrorLine } from '@/components/error-line'
import { EmptyState } from '@/components/empty-state'
import { LoadingRows } from '@/components/loading'
import { Panel } from '@/components/stat'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { describeChannels, describeRhythm, describeSchedule } from '@/lib/alarms'
import { describeError } from '@/lib/errors'
import { useAlarms } from '@/lib/queries'

// Read-only until Phase 5 adds the editor (PLAN.md §19).
export function AlarmsPage() {
  const alarms = useAlarms()
  if (alarms.isError) return <ErrorLine message={describeError(alarms.error)} />
  if (alarms.isPending) return <LoadingRows rows={3} />
  if (alarms.data.length === 0) return <EmptyState message="No alarms" />

  return (
    <Panel title="Alarms">
      <div>
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Label</TableHead>
              <TableHead>Schedule</TableHead>
              <TableHead className="hidden md:table-cell">Rhythm</TableHead>
              <TableHead className="hidden md:table-cell">Channels</TableHead>
              <TableHead className="text-right">Status</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {alarms.data.map((alarm) => (
              <TableRow key={alarm.id}>
                <TableCell className="font-medium">{alarm.label}</TableCell>
                <TableCell className="tabular-nums">{describeSchedule(alarm)}</TableCell>
                <TableCell className="hidden md:table-cell">{describeRhythm(alarm.rhythm)}</TableCell>
                <TableCell className="hidden md:table-cell">{describeChannels(alarm.channels)}</TableCell>
                <TableCell className="text-right">{alarm.enabled ? 'On' : 'Off'}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>
    </Panel>
  )
}
