import { Link } from '@tanstack/react-router'
import { useState } from 'react'
import { toast } from 'sonner'
import { CreateWebhookDialog } from '@/components/create-webhook-dialog'
import { DeleteHookDialog } from '@/components/delete-hook-dialog'
import { EmptyState } from '@/components/empty-state'
import { ErrorLine } from '@/components/error-line'
import { LoadingRows } from '@/components/loading'
import { PageAction } from '@/components/page-action'
import { RotateSecretDialog } from '@/components/rotate-secret-dialog'
import { Switch } from '@/components/switch'
import { Panel } from '@/components/stat'
import { Button } from '@/components/ui/button'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { describeError, isConflict } from '@/lib/errors'
import { useAlarms, useHooks, useMe, useUpdateHook } from '@/lib/queries'
import { formatDateTime } from '@/lib/time'
import type { Hook } from '@/lib/types'
import { AUTH_LABEL, hookAddress } from '@/lib/webhooks'

export function WebhooksPage() {
  const hooks = useHooks()
  const alarms = useAlarms()
  const me = useMe()
  const update = useUpdateHook()
  const [creating, setCreating] = useState(false)
  const [rotating, setRotating] = useState<Hook | null>(null)
  const [deleting, setDeleting] = useState<Hook | null>(null)

  function setEnabled(hook: Hook, enabled: boolean) {
    update.mutate(
      { id: hook.id, changes: { enabled }, version: hook.version },
      {
        onError: (failure) =>
          toast.error(isConflict(failure) ? 'This webhook changed somewhere else. Reload and try again.' : describeError(failure)),
      },
    )
  }

  const newButton = (
    <Button onClick={() => setCreating(true)}>New webhook</Button>
  )

  return (
    <div className="flex flex-col gap-6">
      <PageAction>{newButton}</PageAction>

      {hooks.isError ? (
        <ErrorLine message={describeError(hooks.error)} />
      ) : hooks.isPending || alarms.isPending || me.isPending ? (
        <LoadingRows rows={3} />
      ) : hooks.data.length === 0 ? (
        <EmptyState message="No webhooks" action={<Button variant="outline" onClick={() => setCreating(true)}>New webhook</Button>} />
      ) : (
        <WebhookTable
          hooks={hooks.data}
          alarmLabels={new Map((alarms.data ?? []).map((alarm) => [alarm.id, alarm.label]))}
          tz={me.data?.tz ?? 'UTC'}
          onToggle={setEnabled}
          onRotate={setRotating}
          onDelete={setDeleting}
        />
      )}

      <CreateWebhookDialog open={creating} onOpenChange={setCreating} alarms={alarms.data ?? []} />
      <RotateSecretDialog hook={rotating} onClose={() => setRotating(null)} />
      <DeleteHookDialog hook={deleting} onClose={() => setDeleting(null)} />
    </div>
  )
}

function WebhookTable({
  hooks,
  alarmLabels,
  tz,
  onToggle,
  onRotate,
  onDelete,
}: {
  hooks: Hook[]
  alarmLabels: Map<string, string>
  tz: string
  onToggle: (hook: Hook, enabled: boolean) => void
  onRotate: (hook: Hook) => void
  onDelete: (hook: Hook) => void
}) {
  return (
    <Panel title="Endpoints">
      <div>
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Label</TableHead>
              <TableHead>Address</TableHead>
              <TableHead className="hidden md:table-cell">Auth</TableHead>
              <TableHead className="hidden md:table-cell">Alarm</TableHead>
              <TableHead className="hidden md:table-cell">Last triggered</TableHead>
              <TableHead>Enabled</TableHead>
              <TableHead className="text-right">
                <span className="sr-only">Actions</span>
              </TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {hooks.map((hook) => (
              <TableRow key={hook.id}>
                <TableCell className="whitespace-normal font-medium">{hook.label}</TableCell>
                <TableCell className="whitespace-normal break-all">{hookAddress(hook)}</TableCell>
                <TableCell className="whitespace-normal hidden md:table-cell">{AUTH_LABEL[hook.auth_mode]}</TableCell>
                <TableCell className="whitespace-normal hidden md:table-cell">{(hook.alarm_id && alarmLabels.get(hook.alarm_id)) || '—'}</TableCell>
                <TableCell className="whitespace-normal hidden tabular-nums md:table-cell">
                  {hook.last_triggered_at ? formatDateTime(Date.parse(hook.last_triggered_at), tz) : 'Never'}
                </TableCell>
                <TableCell className="whitespace-normal">
                  <Switch checked={hook.enabled} label={`Enabled, ${hook.label}`} onCheckedChange={(enabled) => onToggle(hook, enabled)} />
                </TableCell>
                <TableCell className="whitespace-normal text-right">
                  <div className="flex flex-wrap justify-end gap-2">
                    <Button
                      variant="ghost"
                      size="sm"
                      aria-label={`Deliveries for ${hook.label}`}
                      render={<Link to="/webhooks/$hookId" params={{ hookId: hook.id }} />}
                    >
                      Deliveries
                    </Button>
                    <Button variant="ghost" size="sm" aria-label={`Rotate secret for ${hook.label}`} onClick={() => onRotate(hook)}>
                      Rotate
                    </Button>
                    <Button variant="ghost" size="sm" aria-label={`Delete ${hook.label}`} onClick={() => onDelete(hook)}>
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
  )
}
