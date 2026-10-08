import { expect, test } from '@playwright/test'
import { EMAIL, password } from './env'

// These tests start signed out; the shared storage state would skip the form.
test.use({ storageState: { cookies: [], origins: [] } })

test('a wrong password shows an error and stays on the sign-in page', async ({ page }) => {
  await page.goto('/login')
  await page.getByLabel('Email', { exact: true }).fill(EMAIL)
  await page.getByLabel('Password', { exact: true }).fill('not-the-password-1')
  await page.getByRole('button', { name: 'Sign in' }).click()

  await expect(page.getByText('Email or password is incorrect.')).toBeVisible()
  await expect(page.getByRole('heading', { level: 1, name: 'Sign in' })).toBeVisible()
})

test('the right password lands on Today', async ({ page }) => {
  await page.goto('/login')
  await page.getByLabel('Email', { exact: true }).fill(EMAIL)
  await page.getByLabel('Password', { exact: true }).fill(password())
  await page.getByRole('button', { name: 'Sign in' }).click()

  await expect(page).toHaveURL(/\/$/)
  await expect(page.getByRole('heading', { level: 1, name: 'Today' })).toBeVisible()
})
