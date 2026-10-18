import { describe, expect, it } from 'vitest'
import { uuidv7 } from './ids'

describe('uuidv7', () => {
  it('carries the Unix millisecond timestamp and the version and variant bits', () => {
    const now = Date.parse('2026-10-07T19:30:00Z')
    const id = uuidv7(now)
    expect(id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/)
    expect(parseInt(id.replace(/-/g, '').slice(0, 12), 16)).toBe(now)
  })

  it('gives a new value on every call', () => {
    expect(uuidv7()).not.toBe(uuidv7())
  })
})
