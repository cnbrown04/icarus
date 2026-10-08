import { useQueryClient } from '@tanstack/react-query'
import { useNavigate } from '@tanstack/react-router'
import { useState, type FormEvent } from 'react'
import { toast } from 'sonner'
import { ApiError } from '@/lib/api'
import { Button } from '@/components/ui/button'
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { ErrorLine } from '@/components/error-line'
import { LoadingBlock } from '@/components/loading'
import { Panel } from '@/components/stat'
import { describeError } from '@/lib/errors'
import { queryKeys, useDeleteAccount, useMe, useUpdateMe } from '@/lib/queries'
import type { Me, MeUpdate } from '@/lib/types'

export function SettingsPage() {
  const me = useMe()
  if (me.isPending) return <LoadingBlock className="h-72" />
  if (me.isError) return <ErrorLine message={describeError(me.error)} />

  return (
    <div className="flex flex-col gap-6">
      <Panel title="Profile">
        <ProfileForm me={me.data} />
      </Panel>
      <Panel title="Data">
        <div className="flex flex-col gap-3">
          <p className="text-xs text-muted-foreground">Every record you have, one JSON object per line.</p>
          <Button variant="outline" className="self-start" render={<a href="/v1/export" download />}>
            Download data
          </Button>
        </div>
      </Panel>
      <Panel title="Delete account">
        <DeleteAccount email={me.data.email} />
      </Panel>
    </div>
  )
}

type FormValues = {
  tz: string
  formula_sex: '' | 'male' | 'female'
  birth_year: string
  height_cm: string
  weight_kg: string
  hr_max: string
}

function toForm(me: Me): FormValues {
  return {
    tz: me.tz,
    formula_sex: me.formula_sex ?? '',
    birth_year: me.birth_year === null ? '' : String(me.birth_year),
    height_cm: me.height_cm === null ? '' : String(me.height_cm),
    weight_kg: me.weight_kg === null ? '' : String(me.weight_kg),
    hr_max: me.hr_max === null ? '' : String(me.hr_max),
  }
}

// Only fields that differ from the saved profile are sent (PATCH semantics).
function toChanges(form: FormValues, me: Me): MeUpdate {
  const changes: MeUpdate = {}
  if (form.tz !== me.tz) changes.tz = form.tz
  const sex = form.formula_sex === '' ? null : form.formula_sex
  if (sex !== me.formula_sex) changes.formula_sex = sex
  const birthYear = numberChange(form.birth_year, me.birth_year)
  if (birthYear !== undefined) changes.birth_year = birthYear
  const height = numberChange(form.height_cm, me.height_cm)
  if (height !== undefined) changes.height_cm = height
  const weight = numberChange(form.weight_kg, me.weight_kg)
  if (weight !== undefined) changes.weight_kg = weight
  const hrMax = numberChange(form.hr_max, me.hr_max)
  if (hrMax !== undefined) changes.hr_max = hrMax
  return changes
}

// undefined when the field is unchanged; null when cleared.
function numberChange(text: string, saved: number | null): number | null | undefined {
  const next = text.trim() === '' ? null : Number(text)
  return next === saved ? undefined : next
}

const TIME_ZONES = (() => {
  try {
    return Intl.supportedValuesOf('timeZone')
  } catch {
    return ['UTC']
  }
})()

const field = 'h-8 border-input'

function ProfileForm({ me }: { me: Me }) {
  const update = useUpdateMe()
  const client = useQueryClient()
  const [form, setForm] = useState<FormValues>(() => toForm(me))
  const [error, setError] = useState<string | null>(null)
  const zones = TIME_ZONES.includes(form.tz) ? TIME_ZONES : [form.tz, ...TIME_ZONES]
  const changes = toChanges(form, me)
  const dirty = Object.keys(changes).length > 0

  function set<K extends keyof FormValues>(key: K, value: FormValues[K]) {
    setForm((current) => ({ ...current, [key]: value }))
  }

  function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setError(null)
    update.mutate(
      { changes, version: me.version },
      {
        onSuccess: (saved) => {
          setForm(toForm(saved))
          toast.success('Profile saved')
        },
        onError: (failure) => {
          // The server returns the current profile; keep the edits and save again against its version.
          if (failure instanceof ApiError && failure.status === 409) {
            client.setQueryData(queryKeys.me, failure.current as Me)
            toast.error('Profile changed in another session. Review your values and save again.')
            return
          }
          setError(describeError(failure))
        },
      },
    )
  }

  return (
    <form className="flex flex-col gap-6" onSubmit={onSubmit} noValidate>
      <div className="grid gap-4 sm:grid-cols-2">
        <div className="flex flex-col gap-2">
          <Label htmlFor="formula-sex">Formula sex</Label>
          <select
            id="formula-sex"
            className={`${field} border bg-background px-2 text-xs`}
            value={form.formula_sex}
            onChange={(event) => set('formula_sex', event.target.value as FormValues['formula_sex'])}
          >
            {/* TODO(shadcn): swap for the select component once CI adds it (scripts/shadcn-components.txt). */}
            <option value="">Not set</option>
            <option value="male">Male</option>
            <option value="female">Female</option>
          </select>
        </div>
        <NumberField id="birth-year" label="Birth year" value={form.birth_year} onChange={(v) => set('birth_year', v)} step={1} />
        <NumberField id="height" label="Height (cm)" value={form.height_cm} onChange={(v) => set('height_cm', v)} step={0.1} />
        <NumberField id="weight" label="Weight (kg)" value={form.weight_kg} onChange={(v) => set('weight_kg', v)} step={0.1} />
        <NumberField id="hr-max" label="HRmax (bpm)" value={form.hr_max} onChange={(v) => set('hr_max', v)} step={1} />
        <div className="flex flex-col gap-2">
          <Label htmlFor="tz">Time zone</Label>
          <select
            id="tz"
            className={`${field} border bg-background px-2 text-xs`}
            value={form.tz}
            onChange={(event) => set('tz', event.target.value)}
          >
            {/* TODO(shadcn): swap for the select component once CI adds it. */}
            {zones.map((zone) => (
              <option key={zone} value={zone}>
                {zone}
              </option>
            ))}
          </select>
        </div>
      </div>
      {error && <ErrorLine message={error} />}
      <div>
        <Button type="submit" disabled={!dirty || update.isPending}>
          Save profile
        </Button>
      </div>
    </form>
  )
}

function NumberField({
  id,
  label,
  value,
  onChange,
  step,
}: {
  id: string
  label: string
  value: string
  onChange: (value: string) => void
  step: number
}) {
  return (
    <div className="flex flex-col gap-2">
      <Label htmlFor={id}>{label}</Label>
      <Input id={id} type="number" inputMode="decimal" step={step} value={value} onChange={(event) => onChange(event.target.value)} />
    </div>
  )
}

function DeleteAccount({ email }: { email: string }) {
  const [open, setOpen] = useState(false)
  const [typed, setTyped] = useState('')
  const remove = useDeleteAccount()
  const navigate = useNavigate()

  return (
    <div className="flex flex-col gap-3">
      <p className="text-xs text-muted-foreground">Deletes every reading, device, alarm and webhook. It cannot be undone.</p>
      <Dialog
        open={open}
        onOpenChange={(next) => {
          setOpen(next)
          if (!next) {
            setTyped('')
            remove.reset()
          }
        }}
      >
        {/* Outline, not destructive: Lyra's destructive tint fails AA contrast. The dialog carries the warning. */}
        <DialogTrigger render={<Button variant="outline" className="self-start" />}>Delete account</DialogTrigger>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Delete account {email}?</DialogTitle>
            <DialogDescription>Type your email address to confirm.</DialogDescription>
          </DialogHeader>
          <div className="flex flex-col gap-2">
            <Label htmlFor="confirm-email">Email</Label>
            <Input id="confirm-email" autoComplete="off" value={typed} onChange={(event) => setTyped(event.target.value)} />
          </div>
          {remove.isError && <ErrorLine message={describeError(remove.error)} />}
          <DialogFooter>
            <DialogClose render={<Button variant="outline" />}>Cancel</DialogClose>
            <Button
              variant="destructive"
              disabled={typed !== email || remove.isPending}
              onClick={() =>
                remove.mutate(email, {
                  onSuccess: () => void navigate({ to: '/login' }),
                })
              }
            >
              Delete account
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}
