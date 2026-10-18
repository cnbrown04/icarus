import { describe, expect, it } from 'vitest'
import { emptyForm, formFromAlarm, toAlarmBody, validateForm } from './alarm-form'
import type { Alarm } from './types'

const base: Alarm = {
  id: '0196a7c2-3f1e-7d4a-9b1e-5c2f8a6d1e30',
  kind: 'scheduled',
  label: ' Wake up ',
  schedule: { time: '06:30', weekdays: [5, 1, 1, 3] },
  rhythm: 'double',
  channels: ['phone', 'band'],
  enabled: true,
  version: 7,
  updated_at: '2026-09-28T19:00:00Z',
  deleted_at: null,
}

describe('alarm form', () => {
  it('requires a label, a time for scheduled alarms and one channel', () => {
    const form = { ...emptyForm(), label: '  ', time: '25:00', channels: [] }
    expect(validateForm(form)).toMatchObject({
      label: 'Enter a label.',
      time: 'Enter a time as HH:MM.',
      channels: 'Pick at least one channel.',
    })
  })

  it('does not ask for a time on webhook alarms', () => {
    expect(validateForm({ ...emptyForm(), kind: 'webhook', time: '' }).time).toBeUndefined()
  })

  it('sends trimmed label, sorted unique weekdays and a null schedule for webhook alarms', () => {
    const scheduled = toAlarmBody(formFromAlarm(base))
    expect(scheduled.label).toBe('Wake up')
    expect(scheduled.schedule).toEqual({ time: '06:30', weekdays: [1, 3, 5] })

    expect(toAlarmBody({ ...formFromAlarm(base), kind: 'webhook' }).schedule).toBeNull()
  })

  it('round-trips a custom rhythm through the form', () => {
    const custom: Alarm = { ...base, rhythm: [{ type: 'buzz', preset: 2, loops: 1 }, { type: 'pause', ms: 300 }] }
    const form = formFromAlarm(custom)
    expect(form.rhythm).toBe('custom')
    expect(toAlarmBody(form).rhythm).toEqual(custom.rhythm)
  })

  it('reports rhythm errors only for custom rhythms', () => {
    const longPause = { type: 'pause' as const, ms: 5_000 }
    const tooLong = { ...emptyForm(), rhythm: 'custom' as const, steps: Array.from({ length: 7 }, () => longPause) }
    expect(validateForm(tooLong).steps).toEqual(['The rhythm is 35 s. The limit is 30 s.'])
    expect(validateForm({ ...tooLong, rhythm: 'single' }).steps).toEqual([])
  })
})
