import { cleanup, screen } from '@testing-library/react'
import { afterEach, describe, expect, it } from 'vitest'
import { renderAt } from './test/render'

afterEach(cleanup)

describe('app shell', () => {
  it('renders the Alarms list inside the shared layout', async () => {
    renderAt('/alarms')

    expect(await screen.findByRole('heading', { level: 1, name: 'Alarms' })).toBeTruthy()
    expect(screen.getByRole('navigation', { name: 'Primary' })).toBeTruthy()
    expect(await screen.findByText('Wake up')).toBeTruthy()
    expect(screen.queryByRole('button', { name: 'New alarm' })).toBeNull()
  })

  it('shows the not-found page for an unknown address', async () => {
    renderAt('/not-a-page')

    expect(await screen.findByRole('heading', { level: 1, name: 'Not found' })).toBeTruthy()
    expect(screen.getByRole('link', { name: 'Go to Today' }).getAttribute('href')).toBe('/')
  })
})
