import { expect, test } from '@playwright/test'

test('Today shows the live heart rate and the heart rate chart from the seeded batches', async ({ page }) => {
  await page.goto('/')
  await expect(page.getByRole('heading', { level: 1, name: 'Today' })).toBeVisible()

  await expect(page.getByText('Now', { exact: true })).toBeVisible()
  await expect(page.getByText(/^\d+\s*bpm$/).first()).toBeVisible()

  await expect(page.getByRole('img', { name: /^Heart rate, \d+ minutes, from \d+ to \d+ bpm$/ })).toBeVisible()
})
