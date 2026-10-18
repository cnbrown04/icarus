import { toast } from 'sonner'
import { useState, type FormEvent } from 'react'
import { ErrorLine } from '@/components/error-line'
import { RhythmBuilder } from '@/components/rhythm-builder'
import { Segmented } from '@/components/segmented'
import { Switch } from '@/components/switch'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Sheet, SheetClose, SheetContent, SheetFooter, SheetHeader, SheetTitle } from '@/components/ui/sheet'
import { type AlarmForm, type AlarmFormErrors, emptyForm, formFromAlarm, isBuiltInRhythm, toAlarmBody, validateForm } from '@/lib/alarm-form'
import type { Alarm, AlarmChannel } from '@/lib/types'
import { describeError, isConflict } from '@/lib/errors'
import { useCreateAlarm, useUpdateAlarm } from '@/lib/queries'
import { BUILT_IN_RHYTHMS } from '@/lib/rhythm'
import { uuidv7 } from '@/lib/ids'

export type AlarmEditorState = { open: boolean; alarm: Alarm | null; session: number }

const KIND_OPTIONS = [
  { value: 'scheduled', label: 'Scheduled' },
  { value: 'webhook', label: 'Webhook' },
  { value: 'relay', label: 'Relay' },
] as const

const WEEKDAYS = [
  { day: 1, label: 'Mon', name: 'Monday' },
  { day: 2, label: 'Tue', name: 'Tuesday' },
  { day: 3, label: 'Wed', name: 'Wednesday' },
  { day: 4, label: 'Thu', name: 'Thursday' },
  { day: 5, label: 'Fri', name: 'Friday' },
  { day: 6, label: 'Sat', name: 'Saturday' },
  { day: 7, label: 'Sun', name: 'Sunday' },
] as const

const RHYTHM_OPTIONS = [...BUILT_IN_RHYTHMS.map((name) => ({ value: name, label: name === 'sos' ? 'SOS' : name[0].toUpperCase() + name.slice(1) })), { value: 'custom', label: 'Custom' }]

const field = 'h-8 border border-input bg-background px-2 text-xs'

function hasErrors(errors: AlarmFormErrors): boolean {
  return errors.label !== undefined || errors.time !== undefined || errors.channels !== undefined || errors.steps.length > 0
}

// The sheet keeps its content mounted while it animates closed, so the editor is rebuilt from `session`.
export function AlarmSheet({
  editor,
  onOpenChange,
}: {
  editor: AlarmEditorState
  onOpenChange: (open: boolean) => void
}) {
  return (
    <Sheet open={editor.open} onOpenChange={onOpenChange}>
      <SheetContent>
        <AlarmEditor key={editor.session} alarm={editor.alarm} onDone={() => onOpenChange(false)} />
      </SheetContent>
    </Sheet>
  )
}

function AlarmEditor({ alarm, onDone }: { alarm: Alarm | null; onDone: () => void }) {
  const [form, setForm] = useState<AlarmForm>(() => (alarm ? formFromAlarm(alarm) : emptyForm()))
  // Edits keep the alarm's id, so a retry after a 409 updates the same row.
  const [id] = useState(() => alarm?.id ?? uuidv7())
  const [version, setVersion] = useState(alarm?.version ?? 0)
  const [attempted, setAttempted] = useState(false)
  const [saveError, setSaveError] = useState<string | null>(null)
  const create = useCreateAlarm()
  const update = useUpdateAlarm()
  const errors = validateForm(form)
  const saving = create.isPending || update.isPending
  const formId = 'alarm-form'

  function set<K extends keyof AlarmForm>(key: K, value: AlarmForm[K]) {
    setForm((current) => ({ ...current, [key]: value }))
  }

  function toggleChannel(channel: AlarmChannel, on: boolean) {
    const channels = on ? [...form.channels, channel] : form.channels.filter((item) => item !== channel)
    set('channels', (['phone', 'band'] as const).filter((item) => channels.includes(item)))
  }

  function toggleDay(day: number) {
    const weekdays = form.weekdays.includes(day) ? form.weekdays.filter((item) => item !== day) : [...form.weekdays, day]
    set('weekdays', weekdays)
  }

  function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setAttempted(true)
    setSaveError(null)
    if (hasErrors(validateForm(form))) return
    const body = toAlarmBody(form)

    const onError = (failure: unknown) => {
      if (isConflict(failure)) {
        // Keep the edits; the next save goes against the version the server now holds.
        const current = failure.current as Alarm | undefined
        if (current) setVersion(current.version)
        toast.error('This alarm changed somewhere else. Your edits are kept. Save again to apply them.')
        return
      }
      setSaveError(describeError(failure))
    }

    if (alarm) {
      update.mutate(
        { id, changes: body, version },
        {
          onSuccess: () => {
            toast.success('Alarm saved')
            onDone()
          },
          onError,
        },
      )
    } else {
      create.mutate(
        { id, ...body },
        {
          onSuccess: () => {
            toast.success('Alarm saved')
            onDone()
          },
          onError,
        },
      )
    }
  }

  // Field errors appear after the first save attempt. Rhythm errors are live, because the total is live.
  const shown = attempted ? errors : { ...errors, label: undefined, time: undefined, channels: undefined }
  const blocked = errors.steps.length > 0 || saving

  return (
    <>
      <SheetHeader>
        <SheetTitle>{alarm ? 'Edit alarm' : 'New alarm'}</SheetTitle>
      </SheetHeader>

      <form id={formId} noValidate onSubmit={onSubmit} className="flex min-h-0 flex-1 flex-col gap-6 overflow-y-auto px-4 pb-4">
        <div className="flex flex-col gap-2">
          <p className="text-xs text-muted-foreground">Type</p>
          <Segmented label="Alarm type" options={KIND_OPTIONS} value={form.kind} onChange={(kind) => set('kind', kind)} />
          {form.kind === 'webhook' && <p className="text-xs text-muted-foreground">Fires when a linked webhook is called.</p>}
        </div>

        <div className="flex flex-col gap-2">
          <Label htmlFor="alarm-label">Label</Label>
          <Input
            id="alarm-label"
            value={form.label}
            aria-invalid={shown.label !== undefined}
            onChange={(event) => set('label', event.target.value)}
          />
          {shown.label && <ErrorLine message={shown.label} />}
        </div>

        {form.kind === 'scheduled' && (
          <>
            <div className="flex flex-col gap-2">
              <Label htmlFor="alarm-time">Time</Label>
              <Input
                id="alarm-time"
                type="time"
                step={60}
                className="w-32"
                value={form.time}
                aria-invalid={shown.time !== undefined}
                onChange={(event) => set('time', event.target.value)}
              />
              {shown.time && <ErrorLine message={shown.time} />}
            </div>
            <div className="flex flex-col gap-2">
              <p className="text-xs text-muted-foreground">Repeat on</p>
              <div role="group" aria-label="Repeat on" className="flex flex-wrap gap-2">
                {WEEKDAYS.map((weekday) => {
                  const pressed = form.weekdays.includes(weekday.day)
                  return (
                    <button
                      key={weekday.day}
                      type="button"
                      aria-label={weekday.name}
                      aria-pressed={pressed}
                      onClick={() => toggleDay(weekday.day)}
                      className={`h-8 w-10 border border-border text-xs hover:bg-muted focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring ${
                        pressed ? 'bg-foreground text-background' : 'bg-background text-foreground'
                      }`}
                    >
                      {weekday.label}
                    </button>
                  )
                })}
              </div>
              {form.weekdays.length === 0 && (
                <p className="text-xs text-muted-foreground">No days selected. Rings once, at the next occurrence.</p>
              )}
            </div>
          </>
        )}

        <div className="flex flex-col gap-2">
          <Label htmlFor="alarm-rhythm">Rhythm</Label>
          {/* TODO(shadcn): swap for the select component once CI adds it (scripts/shadcn-components.txt). */}
          <select
            id="alarm-rhythm"
            className={`${field} self-start`}
            value={form.rhythm}
            onChange={(event) => {
              const value = event.target.value
              set('rhythm', isBuiltInRhythm(value) ? value : 'custom')
            }}
          >
            {RHYTHM_OPTIONS.map((option) => (
              <option key={option.value} value={option.value}>
                {option.label}
              </option>
            ))}
          </select>
          {form.rhythm === 'custom' && (
            <div className="pt-2">
              <RhythmBuilder steps={form.steps} onChange={(steps) => set('steps', steps)} errors={errors.steps} />
            </div>
          )}
        </div>

        <fieldset className="flex flex-col gap-2">
          <legend className="text-xs text-muted-foreground">Channels</legend>
          {(['phone', 'band'] as const).map((channel) => (
            <label key={channel} className="flex items-center gap-2 text-xs">
              {/* TODO(shadcn): swap for the checkbox component once CI adds it (scripts/shadcn-components.txt). */}
              <input
                type="checkbox"
                className="size-4"
                checked={form.channels.includes(channel)}
                onChange={(event) => toggleChannel(channel, event.target.checked)}
              />
              {channel === 'phone' ? 'Phone' : 'Band'}
            </label>
          ))}
          {shown.channels && <ErrorLine message={shown.channels} />}
        </fieldset>

        <div className="flex items-center justify-between gap-4">
          <span className="text-xs">Enabled</span>
          <Switch checked={form.enabled} label="Enabled" onCheckedChange={(enabled) => set('enabled', enabled)} />
        </div>

        {saveError && <ErrorLine message={saveError} />}
      </form>

      <SheetFooter className="flex-row justify-end border-t">
        <SheetClose render={<Button variant="outline" />}>Cancel</SheetClose>
        <Button type="submit" form={formId} disabled={blocked}>
          Save alarm
        </Button>
      </SheetFooter>
    </>
  )
}
