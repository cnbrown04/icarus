import { describe, expect, it } from 'vitest'
import { canAddStep, formatSeconds, RHYTHM_LIMITS, totalMs, validateSteps } from './rhythm'
import type { RhythmStep } from './types'

const buzz = (preset = 1, loops = 1): RhythmStep => ({ type: 'buzz', preset, loops })
const pause = (ms: number): RhythmStep => ({ type: 'pause', ms })

describe('rhythm builder limits', () => {
  it('allows up to 10 steps and blocks the eleventh', () => {
    const ten = Array.from({ length: 10 }, () => buzz())
    expect(canAddStep(ten.slice(0, 9))).toBe(true)
    expect(canAddStep(ten)).toBe(false)
    expect(validateSteps([...ten, buzz()])).toContain('Use at most 10 steps.')
  })

  it('counts each buzz loop as 1 s and a pause as its own length', () => {
    expect(totalMs([buzz(1, 3), pause(500)])).toBe(3_500)
  })

  it('accepts exactly 30 s and blocks 31 s', () => {
    const exact = [buzz(1, 5), buzz(1, 5), buzz(1, 5), pause(5_000), pause(5_000), pause(5_000)]
    expect(totalMs(exact)).toBe(30_000)
    expect(validateSteps(exact)).toEqual([])

    const over = [...exact, buzz(1, 1)]
    expect(validateSteps(over)).toEqual(['The rhythm is 31 s. The limit is 30 s.'])
  })

  it('keeps presets to 1 through 7', () => {
    expect(RHYTHM_LIMITS.preset).toEqual({ min: 1, max: 7 })
    expect(validateSteps([buzz(7, 1)])).toEqual([])
    expect(validateSteps([buzz(0, 1)])).toEqual(['Step 1: preset must be 1 to 7.'])
    expect(validateSteps([buzz(8, 1)])).toEqual(['Step 1: preset must be 1 to 7.'])
  })

  it('keeps loops to 1 through 5 and pauses to 100 through 5000 ms', () => {
    expect(validateSteps([buzz(1, 5)])).toEqual([])
    expect(validateSteps([buzz(1, 6)])).toEqual(['Step 1: loops must be 1 to 5.'])
    expect(validateSteps([pause(100), pause(5_000)])).toEqual([])
    expect(validateSteps([pause(99)])).toEqual(['Step 1: pause must be 100 to 5000 ms.'])
    expect(validateSteps([pause(5_001)])).toEqual(['Step 1: pause must be 100 to 5000 ms.'])
  })

  it('rejects an empty step list and values that are not whole numbers', () => {
    expect(validateSteps([])).toEqual(['Add at least one step.'])
    expect(validateSteps([buzz(Number.NaN, 1)])).toEqual(['Step 1: preset must be 1 to 7.'])
  })

  it('formats seconds with one decimal only when needed', () => {
    expect(formatSeconds(4_000)).toBe('4 s')
    expect(formatSeconds(4_300)).toBe('4.3 s')
  })
})
