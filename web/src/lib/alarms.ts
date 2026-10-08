import type { Alarm, Rhythm } from './types'

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
