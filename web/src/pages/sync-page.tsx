import { Link } from '@tanstack/react-router'
import { EmptyState } from '@/components/empty-state'
import { ErrorLine } from '@/components/error-line'
import { LoadingRows } from '@/components/loading'
import { Panel, Stat } from '@/components/stat'
import { Button } from '@/components/ui/button'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { formatInt } from '@/lib/format'
import { describeError } from '@/lib/errors'
import { useDevices, useMe, useSyncState } from '@/lib/queries'
import { formatAgo, formatClock, formatDateTime } from '@/lib/time'
import type { SyncBatch, SyncCounts } from '@/lib/types'

export function SyncPage() {
  const sync = useSyncState()
  const devices = useDevices()
  const me = useMe()
  if (sync.isError) return <ErrorLine message={describeError(sync.error)} />
  if (me.isError) return <ErrorLine message={describeError(me.error)} />
  if (sync.isPending || devices.isPending || me.isPending || !sync.data || !me.data) return <LoadingRows rows={4} />

  const tz = me.data.tz
  const names = new Map(devices.data?.devices.map((device) => [device.id, device.name]) ?? [])
  const last = sync.data.last_batch_at
  const serverTime = Date.parse(sync.data.server_time)

  return (
    <div className="flex flex-col gap-6">
      <div className="grid gap-4 sm:grid-cols-3">
        <Panel title="Server">
          <Stat label="Server time" value={formatClock(serverTime, tz)} caption={formatDateTime(serverTime, tz)} />
        </Panel>
        <Panel title="Last batch">
          <Stat
            label="Received"
            value={last ? formatClock(Date.parse(last), tz) : null}
            caption={last ? formatAgo(serverTime - Date.parse(last)) : 'No batches yet'}
          />
        </Panel>
        <Panel title="Batches">
          <Stat label="Recent" value={formatInt(sync.data.batches.length)} unit={sync.data.batches.length === 1 ? 'batch' : 'batches'} />
        </Panel>
      </div>

      <Panel title="Batches">
        {sync.data.batches.length === 0 ? (
          <EmptyState
            message="No sync batches yet"
            action={
              <Button variant="outline" render={<Link to="/devices" />}>
                Pair iPhone
              </Button>
            }
          />
        ) : (
          <div>
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Received</TableHead>
                  <TableHead className="hidden md:table-cell">Device</TableHead>
                  <TableHead className="text-right">Rows</TableHead>
                  <TableHead className="hidden text-right md:table-cell">Minutes</TableHead>
                  <TableHead>Status</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {sync.data.batches.map((batch) => (
                  <BatchRow key={batch.id} batch={batch} name={names.get(batch.device_id) ?? 'Unknown phone'} tz={tz} />
                ))}
              </TableBody>
            </Table>
          </div>
        )}
      </Panel>
    </div>
  )
}

function BatchRow({ batch, name, tz }: { batch: SyncBatch; name: string; tz: string }) {
  return (
    <TableRow>
      <TableCell className="tabular-nums">{formatDateTime(Date.parse(batch.received_at), tz)}</TableCell>
      <TableCell className="hidden md:table-cell">{name}</TableCell>
      <TableCell className="text-right tabular-nums">{formatInt(rowCount(batch.counts))}</TableCell>
      <TableCell className="hidden text-right tabular-nums md:table-cell">
        {formatInt(batch.counts.minute_metrics?.upserted ?? 0)}
      </TableCell>
      <TableCell>{capitalise(batch.status)}</TableCell>
    </TableRow>
  )
}

// Time-series rows written by one batch: heart rate, R-R, events and alarm deliveries.
function rowCount(counts: SyncCounts): number {
  return (
    (counts.hr?.inserted ?? 0) +
    (counts.rr?.inserted ?? 0) +
    (counts.events?.inserted ?? 0) +
    (counts.alarm_deliveries?.inserted ?? 0)
  )
}

function capitalise(value: string): string {
  return value.charAt(0).toUpperCase() + value.slice(1)
}
