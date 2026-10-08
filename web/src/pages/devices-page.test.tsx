import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { http, HttpResponse } from 'msw'
import { afterEach, describe, expect, it } from 'vitest'
import { PHONE_ID } from '@/mocks/fixtures'
import { renderAt } from '@/test/render'
import { server } from '@/test/server'

afterEach(cleanup)

describe('devices page', () => {
  it('opens the pairing dialog with a code, a QR image and a countdown', async () => {
    renderAt('/devices')

    fireEvent.click(await screen.findByRole('button', { name: 'Pair iPhone' }))

    const qr = await screen.findByRole('img', { name: 'QR code for pairing the iPhone' })
    expect(qr.getAttribute('src')?.startsWith('data:image/svg+xml')).toBe(true)
    expect(await screen.findByText(/^Expires in \d+:\d{2}$/)).toBeTruthy()
  })

  it('asks for confirmation naming the phone before revoking it', async () => {
    const revoked: string[] = []
    server.use(
      http.delete('/v1/devices/:id', ({ params }) => {
        revoked.push(String(params.id))
        return new HttpResponse(null, { status: 204 })
      }),
    )
    renderAt('/devices')
    fireEvent.click(await screen.findByRole('button', { name: "Revoke Caleb's iPhone" }))

    expect(await screen.findByRole('heading', { name: "Revoke Caleb's iPhone?" })).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }))
    await waitFor(() => expect(screen.queryByRole('heading', { name: "Revoke Caleb's iPhone?" })).toBeNull())
    expect(revoked).toEqual([])

    fireEvent.click(await screen.findByRole('button', { name: "Revoke Caleb's iPhone" }))
    fireEvent.click(await screen.findByRole('button', { name: 'Revoke' }))
    await waitFor(() => expect(revoked).toEqual([PHONE_ID]))
  })
})
