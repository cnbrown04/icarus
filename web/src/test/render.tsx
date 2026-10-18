import { QueryClientProvider } from '@tanstack/react-query'
import { createMemoryHistory, RouterProvider } from '@tanstack/react-router'
import { render } from '@testing-library/react'
import { createAppQueryClient, createAppRouter } from '@/router'

// Renders the whole app (layout, router, query client) at a path, the way the browser does.
export function renderAt(path: string) {
  const client = createAppQueryClient()
  const router = createAppRouter(createMemoryHistory({ initialEntries: [path] }))
  const view = render(
    <QueryClientProvider client={client}>
      <RouterProvider router={router} />
    </QueryClientProvider>,
  )
  return { ...view, client, router }
}
