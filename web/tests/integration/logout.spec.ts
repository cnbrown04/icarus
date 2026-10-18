import { expect, test } from '@playwright/test'
import { BASE_URL, EMAIL, password } from './env'

// Signs in on its own so that signing out does not end the session the other specs share.
test.use({ storageState: { cookies: [], origins: [] } })

test('signing out ends the session and returns to the sign-in page', async ({ page }) => {
  await page.goto('/login')
  await page.getByLabel('Email', { exact: true }).fill(EMAIL)
  await page.getByLabel('Password', { exact: true }).fill(password())
  await page.getByRole('button', { name: 'Sign in' }).click()
  await expect(page.getByRole('heading', { level: 1, name: 'Today' })).toBeVisible()

  await page.getByRole('button', { name: 'Sign out' }).click()
  await expect(page).toHaveURL(`${BASE_URL}/login`)
  await expect(page.getByRole('heading', { level: 1, name: 'Sign in' })).toBeVisible()

  expect((await page.request.get('/v1/me')).status()).toBe(401)
})
