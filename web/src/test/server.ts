import { setupServer } from 'msw/node'

// Handlers are installed per test with a fresh state (see setup.ts), so writes in one test cannot leak into another.
export const server = setupServer()
