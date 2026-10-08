import { cleanup, fireEvent, screen, within } from '@testing-library/react'
import { http, HttpResponse } from 'msw'
import { afterEach, describe, expect, it } from 'vitest'
import { renderAt } from '@/test/render'
import { server } from '@/test/server'

afterEach(cleanup)

describe('WHOOP page', () => {
  it('says the integration is not configured when the server answers 404', async () => {
    server.use(
      http.get('/v1/integrations/whoop', () =>
        HttpResponse.json(
          { type: 'urn:icarus:problem:not-found', title: 'Not found', status: 404 },
          { status: 404, headers: { 'Content-Type': 'application/problem+json' } },
        ),
      ),
    )
    renderAt('/integrations/whoop')

    expect(await screen.findByText('WHOOP integration is not configured on the server.')).toBeTruthy()
    expect(screen.queryByRole('button', { name: 'Connect' })).toBeNull()
    expect(screen.queryByRole('heading', { level: 2, name: 'Today' })).toBeNull()
  })

  it('shows the connection, its scopes and today’s values with the not-stored note', async () => {
    renderAt('/integrations/whoop')

    expect(await screen.findByText('Values are fetched live from WHOOP and are not stored.')).toBeTruthy()
    expect(screen.getByText('read:recovery, read:cycles, read:sleep')).toBeTruthy()
    expect(screen.getByText('Recovery')).toBeTruthy()
    expect(screen.queryByRole('link', { name: 'Connect' })).toBeNull()
  })

  it('confirms before disconnecting and then offers to connect again', async () => {
    renderAt('/integrations/whoop')

    fireEvent.click(await screen.findByRole('button', { name: 'Disconnect' }))
    const dialog = await screen.findByRole('dialog')
    expect(within(dialog).getByRole('heading', { name: 'Disconnect WHOOP?' })).toBeTruthy()
    fireEvent.click(within(dialog).getByRole('button', { name: 'Disconnect' }))

    expect(await screen.findByText('WHOOP is not connected.')).toBeTruthy()
    expect((screen.getByRole('link', { name: 'Connect' }) as HTMLAnchorElement).getAttribute('href')).toBe(
      '/v1/integrations/whoop/connect',
    )
  })
})
