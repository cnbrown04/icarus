import { setupServer } from 'msw/node'
import { createHandlers } from '@/mocks/handlers'

export const server = setupServer(...createHandlers())
