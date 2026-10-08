import { existsSync } from 'node:fs'
import { defineConfig, devices } from '@playwright/test'
import { BASE_URL, STORAGE_FILE } from './tests/integration/env'

// Runs against a real icarus-server that CI or the operator starts first. Run
// scripts/seed-integration.mjs before this config loads, since it writes the storage state.
if (!existsSync(STORAGE_FILE)) {
  throw new Error(`${STORAGE_FILE} is missing. Start the server, then run node scripts/seed-integration.mjs.`)
}

export default defineConfig({
  testDir: './tests/integration',
  forbidOnly: !!process.env.CI,
  // The server allows 5 logins a minute per IP. A retry would replay a login, so failures are not retried.
  retries: 0,
  workers: 1,
  timeout: 60_000,
  // A cold browser on a loaded CI runner can take longer than the mocked suite's 5 s to paint the first page.
  expect: { timeout: 15_000 },
  reporter: [['list'], ['html', { open: 'never' }]],
  outputDir: 'test-results/integration',
  use: {
    baseURL: BASE_URL,
    storageState: STORAGE_FILE,
    trace: 'retain-on-failure',
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
})
