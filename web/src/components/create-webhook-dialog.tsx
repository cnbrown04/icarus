import { useState, type FormEvent } from 'react'
import { ErrorLine } from '@/components/error-line'
import { SecretView } from '@/components/secret-view'
import { Segmented } from '@/components/segmented'
import { Button } from '@/components/ui/button'
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { describeError } from '@/lib/errors'
import { useCreateHook } from '@/lib/queries'
import { originOf, SECRET_URL_WARNING, secretUrl } from '@/lib/webhooks'
import type { Alarm, CreatedHook, Hook } from '@/lib/types'

const AUTH_OPTIONS = [
  { value: 'hmac', label: 'Signature' },
  { value: 'secret_url', label: 'Secret URL' },
] as const

const RATE_LIMIT = { min: 1, max: 60 }
const field = 'h-8 border border-input bg-background px-2 text-xs'

type Created = { hook: CreatedHook; address: string }

// Create, then show the secret once. Closing the dialog drops it from memory (PLAN.md §12.4).
export function CreateWebhookDialog({
  open,
  onOpenChange,
  alarms,
}: {
  open: boolean
  onOpenChange: (open: boolean) => void
  alarms: Alarm[]
}) {
  const [created, setCreated] = useState<Created | null>(null)

  // Every way of closing goes through here, so the secret never survives a close.
  const close = (next: boolean) => {
    if (!next) setCreated(null)
    onOpenChange(next)
  }

  return (
    <Dialog open={open} onOpenChange={close}>
      {/* The secret and the example request need more width than the default dialog. */}
      <DialogContent className={created ? 'sm:max-w-lg' : undefined}>
        {created ? (
          <CreatedView created={created} onDone={() => close(false)} />
        ) : (
          <CreateForm alarms={alarms} onCreated={setCreated} onCancel={() => close(false)} />
        )}
      </DialogContent>
    </Dialog>
  )
}

function CreateForm({
  alarms,
  onCreated,
  onCancel,
}: {
  alarms: Alarm[]
  onCreated: (created: Created) => void
  onCancel: () => void
}) {
  const [label, setLabel] = useState('')
  const [alarmId, setAlarmId] = useState<string>(alarms[0]?.id ?? '')
  const [authMode, setAuthMode] = useState<Hook['auth_mode']>('hmac')
  const [rate, setRate] = useState('10')
  const [attempted, setAttempted] = useState(false)
  const create = useCreateHook()
  const rateValue = Number(rate)
  const rateValid = Number.isInteger(rateValue) && rateValue >= RATE_LIMIT.min && rateValue <= RATE_LIMIT.max
  const labelError = label.trim() === '' ? 'Enter a label.' : undefined
  const rateError = rateValid ? undefined : `Enter 1 to ${RATE_LIMIT.max} per minute.`

  function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setAttempted(true)
    if (labelError || rateError) return
    create.mutate(
      { label: label.trim(), alarm_id: alarmId || null, auth_mode: authMode, rate_limit_per_min: rateValue },
      {
        onSuccess: (hook) => {
          // Only the secret URL's address carries the secret; the signature endpoint's address is public.
          const origin = originOf(hook.url)
          const address = authMode === 'hmac' ? hook.url : secretUrl(origin, hook.slug, hook.secret)
          onCreated({ hook, address })
        },
      },
    )
  }

  return (
    <>
      <DialogHeader>
        <DialogTitle>New webhook</DialogTitle>
      </DialogHeader>
      <form noValidate onSubmit={onSubmit} className="flex flex-col gap-4">
        <div className="flex flex-col gap-2">
          <Label htmlFor="webhook-label">Label</Label>
          <Input
            id="webhook-label"
            value={label}
            aria-invalid={attempted && labelError !== undefined}
            onChange={(event) => setLabel(event.target.value)}
          />
          {attempted && labelError && <ErrorLine message={labelError} />}
        </div>

        <div className="flex flex-col gap-2">
          <Label htmlFor="webhook-alarm">Linked alarm</Label>
          {/* TODO(shadcn): swap for the select component once CI adds it (scripts/shadcn-components.txt). */}
          <select id="webhook-alarm" className={`${field} self-start`} value={alarmId} onChange={(event) => setAlarmId(event.target.value)}>
            <option value="">No alarm</option>
            {alarms.map((alarm) => (
              <option key={alarm.id} value={alarm.id}>
                {alarm.label}
              </option>
            ))}
          </select>
        </div>

        <div className="flex flex-col gap-2">
          <p className="text-xs text-muted-foreground">Auth mode</p>
          <Segmented label="Auth mode" options={AUTH_OPTIONS} value={authMode} onChange={setAuthMode} />
          {authMode === 'secret_url' && (
            <p className="text-xs text-destructive">{SECRET_URL_WARNING}</p>
          )}
        </div>

        <div className="flex flex-col gap-2">
          <Label htmlFor="webhook-rate">Rate limit (per min)</Label>
          <Input
            id="webhook-rate"
            type="number"
            inputMode="numeric"
            min={RATE_LIMIT.min}
            max={RATE_LIMIT.max}
            step={1}
            className="w-24"
            value={rate}
            aria-invalid={attempted && rateError !== undefined}
            onChange={(event) => setRate(event.target.value)}
          />
          {attempted && rateError && <ErrorLine message={rateError} />}
        </div>

        {create.isError && <ErrorLine message={describeError(create.error)} />}

        <DialogFooter>
          <Button variant="outline" type="button" onClick={onCancel}>
            Cancel
          </Button>
          <Button type="submit" disabled={create.isPending}>
            Create webhook
          </Button>
        </DialogFooter>
      </form>
    </>
  )
}

function CreatedView({ created, onDone }: { created: Created; onDone: () => void }) {
  return (
    <>
      <DialogHeader>
        <DialogTitle>Webhook "{created.hook.label}" created</DialogTitle>
        <DialogDescription>
          {created.hook.auth_mode === 'hmac'
            ? 'The signing secret is shown once. Copy it now. It cannot be viewed again.'
            : 'The secret URL is shown once. Copy it now. It cannot be viewed again.'}
        </DialogDescription>
      </DialogHeader>
      <SecretView authMode={created.hook.auth_mode} address={created.address} secret={created.hook.secret} />
      <DialogFooter>
        <Button onClick={onDone}>Done</Button>
      </DialogFooter>
    </>
  )
}
