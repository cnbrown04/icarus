import '@fontsource-variable/jetbrains-mono'
import './index.css'
import { QueryClientProvider } from '@tanstack/react-query'
import { RouterProvider } from '@tanstack/react-router'
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { createAppQueryClient, createAppRouter } from './router'
import { followSystemColorScheme } from './lib/theme'

const rootElement = document.getElementById('root')
if (!rootElement) {
  throw new Error('Missing #root element')
}

// The screenshot build (VITE_MSW=1) serves fixtures through a service worker. Production never loads it.
async function enableMocking() {
  if (import.meta.env.VITE_MSW !== '1') return
  const { worker } = await import('./mocks/browser')
  await worker.start({ onUnhandledRequest: 'bypass', quiet: true })
}

followSystemColorScheme()

const queryClient = createAppQueryClient()
const router = createAppRouter()

void enableMocking().then(() => {
  createRoot(rootElement).render(
    <StrictMode>
      <QueryClientProvider client={queryClient}>
        <RouterProvider router={router} />
      </QueryClientProvider>
    </StrictMode>,
  )
})
