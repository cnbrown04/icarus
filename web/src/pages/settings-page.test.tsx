import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { http, HttpResponse } from 'msw'
import { afterEach, describe, expect, it } from 'vitest'
import { USER } from '@/mocks/fixtures'
import { renderAt } from '@/test/render'
import { server } from '@/test/server'

afterEach(cleanup)

describe('settings page', () => {
  it('keeps the edits and tells the user when the profile changed elsewhere (409)', async () => {
    const current = { ...USER, birth_year: 1991, version: 4 }
    server.use(
      http.patch('/v1/me', () =>
        HttpResponse.json(
          { type: 'urn:icarus:problem:conflict', title: 'Conflict', status: 409, current },
          { status: 409, headers: { 'Content-Type': 'application/problem+json' } },
        ),
      ),
    )
    renderAt('/settings')
    const birthYear = (await screen.findByLabelText('Birth year')) as HTMLInputElement
    fireEvent.change(birthYear, { target: { value: '1990' } })

    fireEvent.click(screen.getByRole('button', { name: 'Save profile' }))

    expect(
      await screen.findByText('Profile changed in another session. Review your values and save again.'),
    ).toBeTruthy()
    expect(birthYear.value).toBe('1990')
  })

  it('sends only the changed fields with If-Match set to the saved version', async () => {
    const seen: { body: unknown; ifMatch: string | null } = { body: null, ifMatch: null }
    server.use(
      http.patch('/v1/me', async ({ request }) => {
        seen.body = await request.json()
        seen.ifMatch = request.headers.get('If-Match')
        return HttpResponse.json({ ...USER, hr_max: 188, version: 4 })
      }),
    )
    renderAt('/settings')
    fireEvent.change(await screen.findByLabelText('HRmax (bpm)'), { target: { value: '188' } })

    fireEvent.click(screen.getByRole('button', { name: 'Save profile' }))

    await waitFor(() => expect(seen.ifMatch).toBe(String(USER.version)))
    expect(seen.body).toEqual({ hr_max: 188 })
  })

  it('confirms account deletion by typing the email address', async () => {
    renderAt('/settings')
    fireEvent.click(await screen.findByRole('button', { name: 'Delete account' }))

    const confirm = await screen.findByRole('button', { name: 'Delete account', hidden: false })
    expect((confirm as HTMLButtonElement).disabled).toBe(true)
    fireEvent.change(screen.getByLabelText('Email'), { target: { value: USER.email } })
    expect((screen.getAllByRole('button', { name: 'Delete account' }).at(-1) as HTMLButtonElement).disabled).toBe(false)
  })
})
