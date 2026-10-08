import { cleanup, screen } from '@testing-library/react'
import { http, HttpResponse } from 'msw'
import { afterEach, describe, expect, it } from 'vitest'
import { renderAt } from '@/test/render'
import { server } from '@/test/server'

afterEach(cleanup)

function noData() {
  server.use(
    http.get('/v1/metrics/live', () => HttpResponse.json({ bpm: null, ts: null })),
    http.get('/v1/metrics/minutes', () => HttpResponse.json({ minutes: [] })),
    http.get('/v1/metrics/hr', ({ request }) =>
      HttpResponse.json({ res: new URL(request.url).searchParams.get('res'), points: [] }),
    ),
    http.get('/v1/metrics/daily', () => HttpResponse.json({ days: [] })),
    http.get('/v1/sync/state', () =>
      HttpResponse.json({ server_time: new Date().toISOString(), last_batch_at: null, batches: [] }),
    ),
  )
}

describe('Today page', () => {
  it('shows the empty state with a link to pair a phone when there is no data', async () => {
    noData()
    renderAt('/')

    expect(await screen.findByText('No data yet')).toBeTruthy()
    const pair = screen.getByRole('link', { name: 'Pair iPhone' })
    expect(pair.getAttribute('href')).toBe('/devices')
    expect(screen.queryByText('Heart rate, 1 min')).toBeNull()
  })

  it('shows live heart rate, the day charts and the estimated calories when data exists', async () => {
    renderAt('/')

    expect(await screen.findByText('Heart rate, 1 min')).toBeTruthy()
    expect(screen.getByRole('heading', { name: 'Stress' })).toBeTruthy()
    expect(screen.getByRole('heading', { name: 'Heart rate' })).toBeTruthy()
    expect(screen.getByText('Now')).toBeTruthy()
    expect(screen.getByRole('heading', { name: 'Resting heart rate' })).toBeTruthy()
    expect(screen.getByText('Estimated')).toBeTruthy()
    expect(screen.getByText('Last sync')).toBeTruthy()
    expect(screen.queryByText('No data yet')).toBeNull()
  })

  it('shows the age of a live reading once it is older than 60 seconds', async () => {
    server.use(
      http.get('/v1/metrics/live', () =>
        HttpResponse.json({ bpm: 62, ts: new Date(Date.now() - 5 * 60_000).toISOString() }),
      ),
    )
    renderAt('/')

    expect(await screen.findByText('Updated 5 min ago')).toBeTruthy()
  })
})
