import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react'
import { http, HttpResponse } from 'msw'
import { afterEach, describe, expect, it } from 'vitest'
import { renderAt } from '@/test/render'
import { server } from '@/test/server'

afterEach(cleanup)

function fill(email: string, password: string) {
  fireEvent.change(screen.getByLabelText('Email'), { target: { value: email } })
  fireEvent.change(screen.getByLabelText('Password'), { target: { value: password } })
  fireEvent.click(screen.getByRole('button', { name: 'Sign in' }))
}

describe('login page', () => {
  it('shows the credentials error line on 401 and stays on the page', async () => {
    renderAt('/login')
    await screen.findByRole('heading', { level: 1, name: 'Sign in' })

    fill('owner@example.com', 'wrong')

    expect((await screen.findByRole('alert')).textContent).toBe('Email or password is incorrect.')
    expect(screen.getByRole('heading', { level: 1, name: 'Sign in' })).toBeTruthy()
  })

  it('tells the user to wait on 429', async () => {
    server.use(
      http.post('/v1/auth/login', () =>
        HttpResponse.json(
          { type: 'urn:icarus:problem:rate-limited', title: 'Too many requests', status: 429 },
          { status: 429, headers: { 'Content-Type': 'application/problem+json' } },
        ),
      ),
    )
    renderAt('/login')
    await screen.findByRole('heading', { level: 1, name: 'Sign in' })

    fill('owner@example.com', 'anything')

    expect((await screen.findByRole('alert')).textContent).toBe('Too many attempts. Wait a minute and try again.')
  })

  it('moves to Today after a successful sign in', async () => {
    const { router } = renderAt('/login')
    await screen.findByRole('heading', { level: 1, name: 'Sign in' })

    fill('owner@example.com', 'correct-password')

    await waitFor(() => expect(router.state.location.pathname).toBe('/'))
  })
})
