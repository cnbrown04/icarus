import { setupWorker } from 'msw/browser'
import { createHandlers } from './handlers'

// Screenshot and local preview builds only (VITE_MSW=1). The service worker script is public/mockServiceWorker.js.
export const worker = setupWorker(...createHandlers())
