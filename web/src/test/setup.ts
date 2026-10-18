import { configure } from '@testing-library/react'
import { afterAll, afterEach, beforeAll, beforeEach, vi } from 'vitest'
import { createHandlers, createState } from '@/mocks/handlers'
import { MOCK_NOW } from '@/mocks/fixtures'
import { server } from './server'

// Routes load lazily, so the first render of a page can take longer than the 1 s default under parallel load.
configure({ asyncUtilTimeout: 3000 })

// Freeze Date at the fixture clock so "now" in components matches the mocks (timers still run).
vi.useFakeTimers({ toFake: ['Date'], now: MOCK_NOW })

// jsdom does not implement scrolling; the router calls it on navigation.
window.scrollTo = () => {}

// jsdom has no matchMedia or ResizeObserver; the sidebar and Recharts need both.
Object.defineProperty(window, 'matchMedia', {
  writable: true,
  value: (query: string): MediaQueryList => ({
    matches: false,
    media: query,
    onchange: null,
    addEventListener: () => {},
    removeEventListener: () => {},
    addListener: () => {},
    removeListener: () => {},
    dispatchEvent: () => false,
  }),
})

class ResizeObserverStub {
  observe() {}
  unobserve() {}
  disconnect() {}
}
globalThis.ResizeObserver = ResizeObserverStub as unknown as typeof ResizeObserver

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
beforeEach(() => server.use(...createHandlers(createState())))
afterEach(() => server.resetHandlers())
afterAll(() => server.close())
