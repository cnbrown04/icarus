import { ErrorLine } from '@/components/error-line'
import { EmptyState } from '@/components/empty-state'
import { LoadingRows } from '@/components/loading'
import { Panel } from '@/components/stat'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { describeError } from '@/lib/errors'
import { useAlarms, useHooks, useMe } from '@/lib/queries'
import { formatDateTime } from '@/lib/time'

// Read-only until Phase 5 adds create, rotate and delete (PLAN.md §19).
export function WebhooksPage() {
  const hooks = useHooks()
  const alarms = useAlarms()
  const me = useMe()
  if (hooks.isError) return <ErrorLine message={describeError(hooks.error)} />
  if (hooks.isPending || alarms.isPending || me.isPending) return <LoadingRows rows={3} />
  if (hooks.data.length === 0) return <EmptyState message="No webhooks" />

  const tz = me.data?.tz ?? 'UTC'
  const alarmLabel = new Map((alarms.data ?? []).map((alarm) => [alarm.id, alarm.label]))

  return (
    <Panel title="Endpoints">
      <div>
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Label</TableHead>
              <TableHead>URL</TableHead>
              <TableHead className="hidden md:table-cell">Auth</TableHead>
              <TableHead className="hidden md:table-cell">Alarm</TableHead>
              <TableHead className="hidden md:table-cell">Last triggered</TableHead>
              <TableHead className="text-right">Status</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {hooks.data.map((hook) => (
              <TableRow key={hook.id}>
                <TableCell className="font-medium">{hook.label}</TableCell>
                <TableCell className="whitespace-normal break-all">{hook.url}</TableCell>
                <TableCell className="hidden md:table-cell">{hook.auth_mode === 'hmac' ? 'Signature' : 'Secret URL'}</TableCell>
                <TableCell className="hidden md:table-cell">{(hook.alarm_id && alarmLabel.get(hook.alarm_id)) || '—'}</TableCell>
                <TableCell className="hidden tabular-nums md:table-cell">
                  {hook.last_triggered_at ? formatDateTime(Date.parse(hook.last_triggered_at), tz) : 'Never'}
                </TableCell>
                <TableCell className="text-right">{hook.enabled ? 'On' : 'Off'}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>
    </Panel>
  )
}
