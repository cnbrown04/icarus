import { describe, expect, it } from 'vitest'
import { hmacCurl, hookAddress, originOf, secretUrl, secretUrlCurl, shellQuote } from './webhooks'
import type { Hook } from './types'

const hook = (overrides: Partial<Hook>): Hook => ({
  id: '0196a7c2-3f1e-7d4a-9b1e-5c2f8a6d1e41',
  slug: 'q4xw8r',
  label: 'Home Assistant',
  alarm_id: null,
  auth_mode: 'hmac',
  rate_limit_per_min: 10,
  enabled: true,
  url: 'https://icarus.example.com/v1/hooks/q4xw8r',
  created_at: '2026-09-22T12:00:00Z',
  last_triggered_at: null,
  version: 1,
  ...overrides,
})

describe('webhook addresses', () => {
  it('shows a signature endpoint in full', () => {
    expect(hookAddress(hook({}))).toBe('https://icarus.example.com/v1/hooks/q4xw8r')
  })

  it('never shows a secret URL secret in the list', () => {
    const address = hookAddress(hook({ auth_mode: 'secret_url', url: 'https://icarus.example.com/v1/hooks/q4xw8r/SECRETVALUE' }))
    expect(address).toBe('https://icarus.example.com/v1/hooks/q4xw8r/[secret]')
    expect(address).not.toContain('SECRETVALUE')
  })

  it('builds a secret URL from the origin, slug and secret', () => {
    expect(originOf('https://icarus.example.com/v1/hooks/q4xw8r')).toBe('https://icarus.example.com')
    expect(secretUrl('https://icarus.example.com', 'q4xw8r', 'abc')).toBe('https://icarus.example.com/v1/hooks/q4xw8r/abc')
  })
})

describe('request examples', () => {
  it('signs with the PLAN.md 12.4 header format', () => {
    const curl = hmacCurl('https://icarus.example.com/v1/hooks/q4xw8r', 'sekret')
    expect(curl).toContain('SECRET=\'sekret\'')
    expect(curl).toContain('openssl dgst -sha256 -hmac "$SECRET"')
    expect(curl).toContain('-H "X-Icarus-Signature: t=$T,v1=$SIG"')
    expect(curl).toContain("printf '%s.%s' \"$T\" \"$BODY\"")
    expect(curl).toContain("curl -sS -X POST 'https://icarus.example.com/v1/hooks/q4xw8r'")
  })

  it('posts a secret URL example with no signature header', () => {
    const curl = secretUrlCurl('https://icarus.example.com/v1/hooks/q4xw8r/abc')
    expect(curl).toContain("'https://icarus.example.com/v1/hooks/q4xw8r/abc'")
    expect(curl).not.toContain('X-Icarus-Signature')
  })

  it('quotes single quotes for bash', () => {
    expect(shellQuote("it's")).toBe(`'it'\\''s'`)
  })
})
