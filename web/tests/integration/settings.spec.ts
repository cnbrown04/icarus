import { readFile } from 'node:fs/promises'
import { expect, test, type Page } from '@playwright/test'

async function exportRecords(page: Page): Promise<{ kind: string }[]> {
  // Identity encoding: the content check does not depend on the compression layer (see the test below).
  const response = await page.request.get('/v1/export', { headers: { 'accept-encoding': 'identity' } })
  expect(response.status()).toBe(200)
  expect(response.headers()['content-type']).toBe('application/x-ndjson')
  const lines = (await response.text()).split('\n').filter((line) => line.length > 0)
  return lines.map((line) => JSON.parse(line) as { kind: string })
}

test('the data link points at the NDJSON export, which includes the account record', async ({ page }) => {
  await page.goto('/settings')
  await expect(page.getByRole('heading', { level: 1, name: 'Settings' })).toBeVisible()
  const link = page.getByRole('link', { name: 'Download data' })
  await expect(link).toHaveAttribute('href', '/v1/export')
  await expect(link).toHaveAttribute('download', '')

  const records = await exportRecords(page)
  expect(records.length).toBeGreaterThan(1)
  expect(records.some((record) => record.kind === 'me')).toBe(true)
})

// Known server bug: GET /v1/export with Accept-Encoding gzip (every browser) is cut off after about 58 KB.
// crates/icarus-api/src/routes/export.rs wraps the channel in futures_util stream::unfold, which panics when the
// compression layer polls it again after it returned None. Remove test.fail once the server streams with a fused
// stream (for example tokio_stream ReceiverStream); the test then passes and the annotation must go.
test.fail('the browser download of the export completes', async ({ page }) => {
  await page.goto('/settings')
  const [download] = await Promise.all([
    page.waitForEvent('download'),
    page.getByRole('link', { name: 'Download data' }).click(),
  ])
  expect(download.suggestedFilename()).toBe('icarus-export.ndjson')

  const path = await download.path()
  expect(path).not.toBeNull()
  const records = (await readFile(path as string, 'utf8'))
    .split('\n')
    .filter((line) => line.length > 0)
    .map((line) => JSON.parse(line) as { kind: string })
  expect(records.some((record) => record.kind === 'me')).toBe(true)
})

test('a profile change saves and reads back after a reload', async ({ page }) => {
  await page.goto('/settings')
  const current = (await (await page.request.get('/v1/me')).json()) as { hr_max: number | null }
  const next = current.hr_max === 181 ? '182' : '181'

  await page.getByLabel('HRmax (bpm)', { exact: true }).fill(next)
  await page.getByRole('button', { name: 'Save profile' }).click()
  await expect(page.getByText('Profile saved', { exact: true })).toBeVisible()

  await page.reload()
  await expect(page.getByLabel('HRmax (bpm)', { exact: true })).toHaveValue(next)
  const saved = (await (await page.request.get('/v1/me')).json()) as { hr_max: number }
  expect(saved.hr_max).toBe(Number(next))
})
