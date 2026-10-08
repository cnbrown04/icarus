import { useState } from 'react'
import { toast } from 'sonner'
import { AlarmSheet, type AlarmEditorState } from '@/components/alarm-sheet'
import { DeleteAlarmDialog } from '@/components/delete-alarm-dialog'
import { EmptyState } from '@/components/empty-state'
import { ErrorLine } from '@/components/error-line'
import { LoadingRows } from '@/components/loading'
import { PageAction } from '@/components/page-action'
import { Switch } from '@/components/switch'
import { Panel } from '@/components/stat'
import { Button } from '@/components/ui/button'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { describeChannels, describeDeliveryStatus, describeDispatchStatus, describeKind, describeRhythm, describeSchedule } from '@/lib/alarms'
import { describeError, isConflict } from '@/lib/errors'
import { useAlarms, useDispatches, useMe, useTestAlarm, useUpdateAlarm } from '@/lib/queries'
import { formatDateTime } from '@/lib/time'
import type { Alarm, Dispatch } from '@/lib/types'

export function AlarmsPage() {
  const alarms = useAlarms()
  const dispatches = useDispatches()
  const me = useMe()
  const update = useUpdateAlarm()
  const test = useTestAlarm()
  const [editor, setEditor] = useState<AlarmEditorState>({ open: false, alarm: null, session: 0 })
  const [deleting, setDeleting] = useState<Alarm | null>(null)

  const openNew = () => setEditor((current) => ({ open: true, alarm: null, session: current.session + 1 }))
  const openEdit = (alarm: Alarm) => setEditor((current) => ({ open: true, alarm, session: current.session + 1 }))

  function setEnabled(alarm: Alarm, enabled: boolean) {
    update.mutate(
      { id: alarm.id, changes: { enabled }, version: alarm.version },
      {
        onError: (failure) =>
          toast.error(
            isConflict(failure)
              ? 'This alarm changed somewhere else. Reload and try again.'
              : describeError(failure),
          ),
      },
    )
  }

  function sendTest(alarm: Alarm) {
    test.mutate(alarm.id, {
      onSuccess: (result) => toast.success('Test sent', { description: `Dispatch ${result.dispatch_id}` }),
      onError: (failure) => toast.error(describeError(failure)),
    })
  }

  return (
    <div className="flex flex-col gap-6">
      <PageAction>
        <Button onClick={openNew}>New alarm</Button>
      </PageAction>

      {alarms.isError ? (
        <ErrorLine message={describeError(alarms.error)} />
      ) : alarms.isPending ? (
        <LoadingRows rows={3} />
      ) : alarms.data.length === 0 ? (
        <EmptyState message="No alarms" action={<Button variant="outline" onClick={openNew}>New alarm</Button>} />
      ) : (
        <Panel title="Alarms">
          <div>
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Label</TableHead>
                  <TableHead className="hidden md:table-cell">Type</TableHead>
                  <TableHead>Schedule</TableHead>
                  <TableHead className="hidden md:table-cell">Rhythm</TableHead>
                  <TableHead className="hidden md:table-cell">Channels</TableHead>
                  <TableHead>Enabled</TableHead>
                  <TableHead className="text-right">
                    <span className="sr-only">Actions</span>
                  </TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {alarms.data.map((alarm) => (
                  <TableRow key={alarm.id}>
                    <TableCell className="whitespace-normal font-medium">{alarm.label}</TableCell>
                    <TableCell className="whitespace-normal hidden md:table-cell">{describeKind(alarm.kind)}</TableCell>
                    <TableCell className="whitespace-normal tabular-nums">{describeSchedule(alarm)}</TableCell>
                    <TableCell className="whitespace-normal hidden md:table-cell">{describeRhythm(alarm.rhythm)}</TableCell>
                    <TableCell className="whitespace-normal hidden md:table-cell">{describeChannels(alarm.channels)}</TableCell>
                    <TableCell className="whitespace-normal">
                      <Switch
                        checked={alarm.enabled}
                        label={`Enabled, ${alarm.label}`}
                        onCheckedChange={(enabled) => setEnabled(alarm, enabled)}
                      />
                    </TableCell>
                    <TableCell className="whitespace-normal text-right">
                      <div className="flex flex-wrap justify-end gap-2">
                        <Button variant="ghost" size="sm" aria-label={`Test ${alarm.label}`} onClick={() => sendTest(alarm)} disabled={test.isPending}>
                          Test
                        </Button>
                        <Button variant="ghost" size="sm" aria-label={`Edit ${alarm.label}`} onClick={() => openEdit(alarm)}>
                          Edit
                        </Button>
                        <Button variant="ghost" size="sm" aria-label={`Delete ${alarm.label}`} onClick={() => setDeleting(alarm)}>
                          Delete
                        </Button>
                      </div>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        </Panel>
      )}

      <Panel title="Recent dispatches">
        {dispatches.isError ? (
          <ErrorLine message={describeError(dispatches.error)} />
        ) : dispatches.isPending || me.isPending || alarms.isPending ? (
          <LoadingRows rows={3} />
        ) : dispatches.data.length === 0 ? (
          <EmptyState message="No dispatches yet" />
        ) : (
          <DispatchTable
            dispatches={dispatches.data}
            labels={new Map((alarms.data ?? []).map((alarm) => [alarm.id, alarm.label]))}
            tz={me.data?.tz ?? 'UTC'}
          />
        )}
      </Panel>

      <AlarmSheet editor={editor} onOpenChange={(open) => setEditor((current) => ({ ...current, open }))} />
      <DeleteAlarmDialog alarm={deleting} onClose={() => setDeleting(null)} />
    </div>
  )
}

// Phone and band outcomes are shown separately and as reported, so a band that did not buzz is not hidden (PLAN.md §9.3).
function DispatchTable({ dispatches, labels, tz }: { dispatches: Dispatch[]; labels: Map<string, string>; tz: string }) {
  return (
    <div>
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Time</TableHead>
            <TableHead className="hidden md:table-cell">Alarm</TableHead>
            <TableHead>Phone</TableHead>
            <TableHead>Band</TableHead>
            <TableHead className="text-right">Status</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {dispatches.map((dispatch) => (
            <TableRow key={dispatch.id}>
              <TableCell className="whitespace-normal tabular-nums">{formatDateTime(Date.parse(dispatch.created_at), tz)}</TableCell>
              <TableCell className="whitespace-normal hidden md:table-cell">{(dispatch.alarm_id && labels.get(dispatch.alarm_id)) || '—'}</TableCell>
              <TableCell className="whitespace-normal">{describeDeliveryStatus(dispatch.phone_status)}</TableCell>
              <TableCell className="whitespace-normal">{describeDeliveryStatus(dispatch.band_status)}</TableCell>
              <TableCell className="whitespace-normal text-right">{describeDispatchStatus(dispatch.status)}</TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </div>
  )
}
