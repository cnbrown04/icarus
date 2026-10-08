import { readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

// Shared by the config and the specs. scripts/seed-integration.mjs writes the files named here.
export const BASE_URL = (process.env.ICARUS_BASE_URL ?? 'http://localhost:8080').replace(/\/$/, '')
export const EMAIL = process.env.ICARUS_E2E_EMAIL ?? 'e2e@example.com'
export const STATE_DIR = process.env.ICARUS_E2E_DIR ?? join(tmpdir(), 'icarus-e2e')
export const STORAGE_FILE = join(STATE_DIR, 'storage.json')
const SEED_FILE = join(STATE_DIR, 'seed.json')

export type SeededDevice = { id: string; name: string; token: string }
export type SeedState = {
  alarm: { id: string; label: string }
  phone: SeededDevice
}

export function readSeed(): SeedState {
  return JSON.parse(readFileSync(SEED_FILE, 'utf8')) as SeedState
}

export function password(): string {
  const value = process.env.ICARUS_E2E_PASSWORD
  if (!value) throw new Error('ICARUS_E2E_PASSWORD is not set. Use the password the test user was created with.')
  return value
}
