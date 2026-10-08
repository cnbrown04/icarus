import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import { afterEach, describe, expect, it } from 'vitest'
import { renderAt } from '@/test/render'

afterEach(cleanup)

// Fixture secrets from src/mocks/handlers.ts. They are not real credentials.
const CREATED_SECRET = 'c2VjcmV0LWZpeHR1cmUtMzItYnl0ZXMtYmFzZTY0dXJs'
const ROTATED_SECRET = 'cm90YXRlZC1maXh0dXJlLXNlY3JldC0zMi1ieXRlcw'
const FRONT_DOOR = '0196a7c2-3f1e-7d4a-9b1e-5c2f8a6d1e40'

describe('webhooks page', () => {
  it('shows the secret once after create and removes it when the dialog closes', async () => {
    renderAt('/webhooks')

    fireEvent.click(await screen.findByRole('button', { name: 'New webhook' }))
    fireEvent.change(await screen.findByLabelText('Label'), { target: { value: 'Garage' } })
    fireEvent.click(screen.getByRole('button', { name: 'Create webhook' }))

    expect(await screen.findByRole('heading', { name: 'Webhook "Garage" created' })).toBeTruthy()
    expect(screen.getByText(CREATED_SECRET)).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Copy signing secret' })).toBeTruthy()

    fireEvent.click(screen.getByRole('button', { name: 'Done' }))
    await waitFor(() => expect(screen.queryByText(CREATED_SECRET)).toBeNull())

    fireEvent.click(screen.getByRole('button', { name: 'New webhook' }))
    expect(await screen.findByLabelText('Label')).toBeTruthy()
    expect(screen.queryByText(CREATED_SECRET)).toBeNull()
  })

  it('confirms a rotation by name, then shows the new secret once', async () => {
    renderAt('/webhooks')

    fireEvent.click(await screen.findByRole('button', { name: 'Rotate secret for Front door' }))
    expect(await screen.findByRole('heading', { name: 'Rotate secret for "Front door"?' })).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Rotate secret' }))

    expect(await screen.findByText(ROTATED_SECRET)).toBeTruthy()
    expect(screen.getByRole('heading', { name: 'New secret for "Front door"' })).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Done' }))
    await waitFor(() => expect(screen.queryByText(ROTATED_SECRET)).toBeNull())
  })

  it('never shows a secret URL secret in the endpoint list', async () => {
    renderAt('/webhooks')

    expect(await screen.findByText('https://icarus.example.com/v1/hooks/q4xw8r/[secret]')).toBeTruthy()
    expect(screen.queryByText(/cm90|c2Vj/)).toBeNull()
  })

  it('pages the deliveries log with Load more until the last page', async () => {
    renderAt(`/webhooks/${FRONT_DOOR}`)

    expect(await screen.findByRole('heading', { name: 'Front door' })).toBeTruthy()
    const rows = () => screen.getAllByRole('row').length - 1
    await waitFor(() => expect(rows()).toBe(10))

    fireEvent.click(screen.getByRole('button', { name: 'Load more' }))
    await waitFor(() => expect(rows()).toBe(20))

    fireEvent.click(screen.getByRole('button', { name: 'Load more' }))
    await waitFor(() => expect(rows()).toBe(26))
    expect(screen.queryByRole('button', { name: 'Load more' })).toBeNull()
  })

  it('shows a rejected signature and a band that was not connected as they were reported', async () => {
    renderAt(`/webhooks/${FRONT_DOOR}`)

    expect(await screen.findByText('Rejected')).toBeTruthy()
    expect(screen.getAllByText('Invalid').length).toBeGreaterThan(0)
    expect(screen.getAllByText('Not connected').length).toBeGreaterThan(0)
    expect(within(screen.getByRole('table')).getAllByRole('row').length).toBeGreaterThan(1)
  })
})
