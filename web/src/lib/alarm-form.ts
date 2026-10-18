import { BUILT_IN_RHYTHMS, defaultStep, validateSteps, type BuiltInRhythm } from './rhythm'
import type { Alarm, AlarmChannel, AlarmInput, RhythmStep } from './types'

// The editor's state. Rhythm is either a built-in name or 'custom', in which case `steps` is used.
export type RhythmChoice = BuiltInRhythm | 'custom'

export type AlarmForm = {
  kind: Alarm['kind']
  label: string
  time: string
  weekdays: number[]
  rhythm: RhythmChoice
  steps: RhythmStep[]
  channels: AlarmChannel[]
  enabled: boolean
}

export type AlarmFormErrors = {
  label?: string
  time?: string
  channels?: string
  steps: string[]
}

const TIME = /^([01]\d|2[0-3]):[0-5]\d$/

// A starting custom rhythm, so switching to "Custom" shows something to edit.
const STARTER_STEPS: RhythmStep[] = [defaultStep('buzz'), defaultStep('pause'), defaultStep('buzz')]

export function emptyForm(): AlarmForm {
  return {
    kind: 'scheduled',
    label: '',
    time: '07:00',
    weekdays: [1, 2, 3, 4, 5],
    rhythm: 'single',
    steps: STARTER_STEPS,
    channels: ['phone'],
    enabled: true,
  }
}

export function formFromAlarm(alarm: Alarm): AlarmForm {
  const rhythm = alarm.rhythm
  return {
    kind: alarm.kind,
    label: alarm.label,
    time: alarm.schedule?.time ?? '07:00',
    weekdays: alarm.schedule?.weekdays ?? [1, 2, 3, 4, 5],
    rhythm: typeof rhythm === 'string' ? rhythm : 'custom',
    steps: typeof rhythm === 'string' ? STARTER_STEPS : rhythm,
    channels: alarm.channels,
    enabled: alarm.enabled,
  }
}

export function validateForm(form: AlarmForm): AlarmFormErrors {
  const errors: AlarmFormErrors = { steps: [] }
  if (form.label.trim() === '') errors.label = 'Enter a label.'
  if (form.kind === 'scheduled' && !TIME.test(form.time)) errors.time = 'Enter a time as HH:MM.'
  if (form.channels.length === 0) errors.channels = 'Pick at least one channel.'
  if (form.rhythm === 'custom') errors.steps = validateSteps(form.steps)
  return errors
}

export type AlarmBody = Omit<AlarmInput, 'id'>

// Call only after validateForm returns no errors.
export function toAlarmBody(form: AlarmForm): AlarmBody {
  const scheduled = form.kind === 'scheduled'
  return {
    kind: form.kind,
    label: form.label.trim(),
    schedule: scheduled ? { time: form.time, weekdays: [...new Set(form.weekdays)].sort((a, b) => a - b) } : null,
    rhythm: form.rhythm === 'custom' ? form.steps : form.rhythm,
    channels: form.channels,
    enabled: form.enabled,
  }
}

export function isBuiltInRhythm(value: string): value is BuiltInRhythm {
  return (BUILT_IN_RHYTHMS as readonly string[]).includes(value)
}
