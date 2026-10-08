import type { RhythmStep } from './types'

// Built-in rhythms are named by the server (contract: Alarms). Custom rhythms are step lists.
export const BUILT_IN_RHYTHMS = ['single', 'double', 'triple', 'long', 'ramp', 'sos'] as const
export type BuiltInRhythm = (typeof BUILT_IN_RHYTHMS)[number]

export const RHYTHM_LIMITS = {
  maxSteps: 10,
  maxTotalMs: 30_000,
  preset: { min: 1, max: 7 },
  loops: { min: 1, max: 5 },
  pauseMs: { min: 100, max: 5000 },
} as const

// Each buzz loop counts as 1 s; a pause counts its own length (contract: Alarms, PLAN.md §9.2).
export function stepMs(step: RhythmStep): number {
  return step.type === 'buzz' ? step.loops * 1000 : step.ms
}

export function totalMs(steps: RhythmStep[]): number {
  return steps.reduce((sum, step) => sum + stepMs(step), 0)
}

// "4 s" or "4.3 s": one decimal only when it is needed.
export function formatSeconds(ms: number): string {
  const tenths = Math.round(ms / 100)
  return tenths % 10 === 0 ? `${tenths / 10} s` : `${(tenths / 10).toFixed(1)} s`
}

export function defaultStep(type: RhythmStep['type']): RhythmStep {
  return type === 'buzz' ? { type: 'buzz', preset: 1, loops: 1 } : { type: 'pause', ms: 300 }
}

export function canAddStep(steps: RhythmStep[]): boolean {
  return steps.length < RHYTHM_LIMITS.maxSteps
}

function inRange(value: number, range: { min: number; max: number }): boolean {
  return Number.isInteger(value) && value >= range.min && value <= range.max
}

// Messages for everything that blocks saving a custom rhythm. Empty means the rhythm can be saved.
export function validateSteps(steps: RhythmStep[]): string[] {
  const errors: string[] = []
  if (steps.length === 0) errors.push('Add at least one step.')
  if (steps.length > RHYTHM_LIMITS.maxSteps) errors.push(`Use at most ${RHYTHM_LIMITS.maxSteps} steps.`)
  steps.forEach((step, index) => {
    const n = index + 1
    if (step.type === 'buzz') {
      if (!inRange(step.preset, RHYTHM_LIMITS.preset)) errors.push(`Step ${n}: preset must be 1 to 7.`)
      if (!inRange(step.loops, RHYTHM_LIMITS.loops)) errors.push(`Step ${n}: loops must be 1 to 5.`)
    } else if (!inRange(step.ms, RHYTHM_LIMITS.pauseMs)) {
      errors.push(`Step ${n}: pause must be 100 to 5000 ms.`)
    }
  })
  const total = totalMs(steps)
  if (Number.isFinite(total) && total > RHYTHM_LIMITS.maxTotalMs) {
    errors.push(`The rhythm is ${formatSeconds(total)}. The limit is 30 s.`)
  }
  return errors
}
