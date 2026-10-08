import { cleanup, screen } from '@testing-library/react'
import { afterEach, describe, expect, it } from 'vitest'
import { renderAt } from './test/render'

afterEach(cleanup)

describe('app shell', () => {
  it('renders the Alarms list inside the shared layout', async () => {
    renderAt('/alarms')

    expect(await screen.findByRole('heading', { level: 1, name: 'Alarms' })).toBeTruthy()
    expect(screen.getByRole('navigation', { name: 'Primary' })).toBeTruthy()
    expect((await screen.findAllByRole('cell', { name: 'Wake up' })).length).toBeGreaterThan(0)
    expect(screen.getByRole('button', { name: 'New alarm' })).toBeTruthy()
  })

  it('lists WHOOP below Settings in the sidebar', async () => {
    renderAt('/settings')

    const nav = await screen.findByRole('navigation', { name: 'Primary' })
    const labels = Array.from(nav.querySelectorAll('a'), (link) => link.textContent?.trim())
    expect(labels.slice(-2)).toEqual(['Settings', 'WHOOP'])
  })

  it('shows the not-found page for an unknown address', async () => {
    renderAt('/not-a-page')

    expect(await screen.findByRole('heading', { level: 1, name: 'Not found' })).toBeTruthy()
    expect(screen.getByRole('link', { name: 'Go to Today' }).getAttribute('href')).toBe('/')
  })
})
