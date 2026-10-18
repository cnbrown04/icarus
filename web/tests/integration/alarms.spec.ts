import { expect, test } from '@playwright/test'

test('a new alarm made in the sheet appears in the table and in the API', async ({ page }) => {
  const label = `E2E alarm ${Date.now()}`
  await page.goto('/alarms')
  await expect(page.getByRole('heading', { level: 1, name: 'Alarms' })).toBeVisible()

  await page.getByRole('button', { name: 'New alarm', exact: true }).click()
  const sheet = page.getByRole('dialog', { name: 'New alarm' })
  await expect(sheet).toBeVisible()
  await sheet.getByLabel('Label', { exact: true }).fill(label)
  await sheet.getByRole('button', { name: 'Save alarm' }).click()

  await expect(sheet).toBeHidden()
  await expect(page.getByRole('cell', { name: label, exact: true })).toBeVisible()

  const response = await page.request.get('/v1/alarms')
  expect(response.status()).toBe(200)
  const { alarms } = (await response.json()) as { alarms: { label: string; kind: string; channels: string[]; enabled: boolean }[] }
  expect(alarms).toContainEqual(expect.objectContaining({ label, kind: 'scheduled', channels: ['phone'], enabled: true }))
})
