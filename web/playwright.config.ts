import { defineConfig } from '@playwright/test'

export default defineConfig({
  testDir: './tests/e2e',
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  reporter: [['list'], ['html', { open: 'never' }]],
  use: {
    baseURL: 'http://localhost:4173',
    trace: 'retain-on-failure',
  },
  // The e2e build serves fixtures through MSW (VITE_MSW=1), so screenshots show data without a server.
  webServer: {
    command: 'pnpm build && pnpm preview --port 4173 --strictPort',
    env: { VITE_MSW: '1' },
    url: 'http://localhost:4173',
    reuseExistingServer: !process.env.CI,
  },
})
