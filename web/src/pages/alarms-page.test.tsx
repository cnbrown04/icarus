import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react'
import { http, HttpResponse } from 'msw'
import { afterEach, describe, expect, it } from 'vitest'
import { ALARMS } from '@/mocks/fixtures'
import { renderAt } from '@/test/render'
import { server } from '@/test/server'

afterEach(cleanup)

const problem = (status: number, slug: string, title: string, extra: object) =>
  HttpResponse.json({ type: `urn:icarus:problem:${slug}`, title, status, ...extra }, { status, headers: { 'Content-Type': 'application/problem+json' } })

const UUID_V7 = /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

describe('alarms page', () => {
  it('creates a scheduled alarm with a custom rhythm, a UUIDv7 id and no If-Match', async () => {
    const sent: { body: Record<string, unknown>; ifMatch: string | null; csrf: string | null }[] = []
    server.use(
      http.post('/v1/alarms', async ({ request }) => {
        const body = (await request.json()) as Record<string, unknown>
        sent.push({ body, ifMatch: request.headers.get('If-Match'), csrf: request.headers.get('X-Icarus-CSRF') })
        return HttpResponse.json({ ...body, version: 1, updated_at: '2026-10-07T19:30:00Z', deleted_at: null }, { status: 201 })
      }),
    )
    renderAt('/alarms')

    fireEvent.click(await screen.findByRole('button', { name: 'New alarm' }))
    fireEvent.change(await screen.findByLabelText('Label'), { target: { value: 'Gym' } })
    fireEvent.change(screen.getByLabelText('Rhythm'), { target: { value: 'custom' } })
    expect(screen.getByText('Total 2.3 s of 30 s')).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Save alarm' }))

    await waitFor(() => expect(sent).toHaveLength(1))
    expect(sent[0].ifMatch).toBeNull()
    expect(sent[0].csrf).toBe('1')
    expect(String(sent[0].body.id)).toMatch(UUID_V7)
    expect(sent[0].body).toMatchObject({
      kind: 'scheduled',
      label: 'Gym',
      schedule: { time: '07:00', weekdays: [1, 2, 3, 4, 5] },
      channels: ['phone'],
      enabled: true,
      rhythm: [
        { type: 'buzz', preset: 1, loops: 1 },
        { type: 'pause', ms: 300 },
        { type: 'buzz', preset: 1, loops: 1 },
      ],
    })
  })

  it('blocks saving a rhythm over 30 s and says by how much', async () => {
    renderAt('/alarms')
    fireEvent.click(await screen.findByRole('button', { name: 'New alarm' }))
    fireEvent.change(await screen.findByLabelText('Rhythm'), { target: { value: 'custom' } })

    fireEvent.change(screen.getByLabelText('Step 2 pause'), { target: { value: '5000' } })
    for (let step = 4; step <= 8; step++) {
      fireEvent.click(screen.getByRole('button', { name: 'Add pause' }))
      fireEvent.change(screen.getByLabelText(`Step ${step} pause`), { target: { value: '5000' } })
    }

    expect(screen.getByText('Total 32 s of 30 s')).toBeTruthy()
    expect(screen.getByText('The rhythm is 32 s. The limit is 30 s.')).toBeTruthy()
    expect((screen.getByRole('button', { name: 'Save alarm' }) as HTMLButtonElement).disabled).toBe(true)
  })

  it('keeps the edits after a 409 and saves again against the version the server now has', async () => {
    const ifMatch: string[] = []
    server.use(
      http.patch('/v1/alarms/:id', async ({ request }) => {
        ifMatch.push(request.headers.get('If-Match') ?? '')
        if (ifMatch.length === 1) {
          return problem(409, 'conflict', 'Conflict', { detail: 'The alarm changed.', current: { ...ALARMS[0], version: 9 } })
        }
        return HttpResponse.json({ ...ALARMS[0], ...((await request.json()) as object), version: 10 })
      }),
    )
    renderAt('/alarms')

    fireEvent.click(await screen.findByRole('button', { name: 'Edit Wake up' }))
    const label = (await screen.findByLabelText('Label')) as HTMLInputElement
    fireEvent.change(label, { target: { value: 'Wake up early' } })
    fireEvent.click(screen.getByRole('button', { name: 'Save alarm' }))

    expect(await screen.findByText(/This alarm changed somewhere else/)).toBeTruthy()
    expect(label.value).toBe('Wake up early')

    fireEvent.click(screen.getByRole('button', { name: 'Save alarm' }))
    await waitFor(() => expect(ifMatch).toEqual([String(ALARMS[0].version), '9']))
  })

  it('sends a test and names the dispatch it created', async () => {
    renderAt('/alarms')
    fireEvent.click(await screen.findByRole('button', { name: 'Test Wake up' }))

    expect(await screen.findByText('Test sent')).toBeTruthy()
    expect(await screen.findByText(/^Dispatch 0196a7c2-3f1e-7d4a-9b1e-[0-9a-f]{12}$/)).toBeTruthy()
  })

  it('asks for confirmation naming the alarm before deleting it', async () => {
    const deleted: string[] = []
    server.use(
      http.delete('/v1/alarms/:id', ({ params, request }) => {
        deleted.push(`${String(params.id)}:${request.headers.get('If-Match')}`)
        return new HttpResponse(null, { status: 204 })
      }),
    )
    renderAt('/alarms')

    fireEvent.click(await screen.findByRole('button', { name: 'Delete Wake up' }))
    expect(await screen.findByRole('heading', { name: 'Delete alarm "Wake up"?' })).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }))
    await waitFor(() => expect(screen.queryByRole('heading', { name: 'Delete alarm "Wake up"?' })).toBeNull())
    expect(deleted).toEqual([])

    fireEvent.click(await screen.findByRole('button', { name: 'Delete Wake up' }))
    const dialog = await screen.findByRole('dialog')
    fireEvent.click(within(dialog).getByRole('button', { name: 'Delete' }))
    await waitFor(() => expect(deleted).toEqual([`${ALARMS[0].id}:${ALARMS[0].version}`]))
  })
})
