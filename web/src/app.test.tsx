import { QueryClientProvider } from '@tanstack/react-query'
import { createMemoryHistory, RouterProvider } from '@tanstack/react-router'
import { cleanup, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it } from 'vitest'
import { createAppQueryClient, createAppRouter } from './router'

function renderAt(path: string) {
  const router = createAppRouter(createMemoryHistory({ initialEntries: [path] }))
  return render(
    <QueryClientProvider client={createAppQueryClient()}>
      <RouterProvider router={router} />
    </QueryClientProvider>,
  )
}

afterEach(cleanup)

describe('app layout', () => {
  it('renders the Alarms page with its empty state inside the shared layout', async () => {
    renderAt('/alarms')

    expect(await screen.findByRole('heading', { level: 1, name: 'Alarms' })).toBeTruthy()
    expect(screen.getByRole('navigation', { name: 'Primary' })).toBeTruthy()
    expect(screen.getByText('No alarms')).toBeTruthy()
    expect(screen.getByRole('button', { name: 'New alarm' })).toBeTruthy()
  })

  it('renders the Today page with its empty state', async () => {
    renderAt('/')

    expect(await screen.findByRole('heading', { level: 1, name: 'Today' })).toBeTruthy()
    expect(screen.getByText('No data yet')).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Pair iPhone' })).toBeTruthy()
  })
})
