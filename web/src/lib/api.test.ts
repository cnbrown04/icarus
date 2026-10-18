import { afterEach, describe, expect, it, vi } from 'vitest'
import { http, HttpResponse } from 'msw'
import { api, ApiError, buildPath, setUnauthorizedHandler } from './api'
import { server } from '@/test/server'

afterEach(() => {
  setUnauthorizedHandler(() => window.location.assign('/login'))
})

describe('api client', () => {
  it('sends the CSRF header on writes only', async () => {
    const methods: { method: string; csrf: string | null }[] = []
    server.use(
      http.get('/v1/probe', ({ request }) => {
        methods.push({ method: request.method, csrf: request.headers.get('X-Icarus-CSRF') })
        return HttpResponse.json({ ok: true })
      }),
      http.post('/v1/probe', ({ request }) => {
        methods.push({ method: request.method, csrf: request.headers.get('X-Icarus-CSRF') })
        return new HttpResponse(null, { status: 204 })
      }),
    )

    await api.get('/v1/probe')
    await api.post('/v1/probe', { a: 1 })

    expect(methods).toEqual([
      { method: 'GET', csrf: null },
      { method: 'POST', csrf: '1' },
    ])
  })

  it('turns problem+json into a typed ApiError with the current entity', async () => {
    server.use(
      http.patch('/v1/me', () =>
        HttpResponse.json(
          {
            type: 'urn:icarus:problem:conflict',
            title: 'Conflict',
            status: 409,
            detail: 'The profile changed.',
            current: { version: 9 },
          },
          { status: 409, headers: { 'Content-Type': 'application/problem+json' } },
        ),
      ),
    )

    const error = await api.patch('/v1/me', {}, 3).catch((caught: unknown) => caught)

    expect(error).toBeInstanceOf(ApiError)
    expect(error).toMatchObject({ status: 409, slug: 'conflict', detail: 'The profile changed.', current: { version: 9 } })
  })

  it('sends If-Match on PATCH', async () => {
    let ifMatch: string | null = null
    server.use(
      http.patch('/v1/me', ({ request }) => {
        ifMatch = request.headers.get('If-Match')
        return HttpResponse.json({})
      }),
    )
    await api.patch('/v1/me', { tz: 'UTC' }, 12)
    expect(ifMatch).toBe('12')
  })

  it('sends the browser to /login on 401 except for the login request itself', async () => {
    const handler = vi.fn()
    setUnauthorizedHandler(handler)
    server.use(
      http.get('/v1/me', () =>
        HttpResponse.json({ type: 'urn:icarus:problem:unauthorized', title: 'Unauthorized', status: 401 }, { status: 401 }),
      ),
    )

    await expect(api.get('/v1/me')).rejects.toBeInstanceOf(ApiError)
    expect(handler).toHaveBeenCalledTimes(1)

    await expect(api.post('/v1/auth/login', { email: 'a', password: 'wrong' })).rejects.toMatchObject({ status: 401 })
    expect(handler).toHaveBeenCalledTimes(1)
  })

  it('maps a dropped connection to a network ApiError', async () => {
    server.use(http.get('/v1/me', () => HttpResponse.error()))

    await expect(api.get('/v1/me')).rejects.toMatchObject({ status: 0, slug: 'network' })
  })

  it('builds query strings without empty values', () => {
    expect(buildPath('/v1/metrics/hr', { from: '2026-10-07T05:00:00Z', to: undefined, res: '1m' })).toBe(
      '/v1/metrics/hr?from=2026-10-07T05%3A00%3A00Z&res=1m',
    )
    expect(buildPath('/v1/me')).toBe('/v1/me')
  })
})
