import type { Alarm, Dispatch, Rhythm } from './types'

const WEEKDAY_SHORT = ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'] as const

// ISO weekdays: 1 is Monday (contract: Schedule).
export function describeWeekdays(weekdays: number[]): string {
  if (weekdays.length === 0) return 'Once'
  const days = [...new Set(weekdays)].sort((a, b) => a - b)
  if (days.length === 7) return 'Every day'
  if (days.join(',') === '1,2,3,4,5') return 'Weekdays'
  if (days.join(',') === '6,7') return 'Weekends'
  return days.map((day) => WEEKDAY_SHORT[day] ?? String(day)).join(' ')
}

export function describeSchedule(alarm: Alarm): string {
  if (alarm.schedule === null) return '—'
  return `${alarm.schedule.time} · ${describeWeekdays(alarm.schedule.weekdays)}`
}

const BUILT_IN: Record<string, string> = {
  single: 'Single',
  double: 'Double',
  triple: 'Triple',
  long: 'Long',
  ramp: 'Ramp',
  sos: 'SOS',
}

export function describeRhythm(rhythm: Rhythm): string {
  if (typeof rhythm === 'string') return BUILT_IN[rhythm] ?? rhythm
  return `Custom, ${rhythm.length} ${rhythm.length === 1 ? 'step' : 'steps'}`
}

export function describeChannels(channels: Alarm['channels']): string {
  if (channels.length === 0) return '—'
  return channels.map((channel) => (channel === 'phone' ? 'Phone' : 'Band')).join(', ')
}

export function describeKind(kind: Alarm['kind']): string {
  return { scheduled: 'Scheduled', webhook: 'Webhook', relay: 'Relay' }[kind]
}

// Phone and band outcomes are shown as reported. "Sent" for the band means the command was accepted,
// not that the band is known to have buzzed (PLAN.md §9.3, delivery honesty).
export function describeDeliveryStatus(status: string | null): string {
  if (status === null) return '—'
  const labels: Record<string, string> = {
    shown: 'Shown',
    ok: 'Sent',
    not_connected: 'Not connected',
    disabled: 'Disabled',
    failed: 'Failed',
  }
  return labels[status] ?? status.replace(/_/g, ' ')
}

export function describeDispatchStatus(status: Dispatch['status']): string {
  return { pending: 'Pending', sent: 'Sent', acked: 'Acknowledged', unacked: 'Not acknowledged', failed: 'Failed' }[status]
}
