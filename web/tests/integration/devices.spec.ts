import { expect, test } from '@playwright/test'
import { BASE_URL, readSeed } from './env'

// Pairs its own phone so the test can run again without reseeding: a revoked token stays revoked.
test('revoking a phone stops its device token; the other phone keeps working', async ({ page, playwright }) => {
  const seed = readSeed()
  const name = `Revoke me ${Date.now()}`

  const { code } = (await (
    await page.request.post('/v1/devices/pairing-codes', { headers: { 'x-icarus-csrf': '1' } })
  ).json()) as { code: string }
  const paired = await page.request.post('/v1/devices/pair', {
    data: { code, name, model: 'iPhone 17', os_version: '26.0', app_version: '1.0.0' },
  })
  expect(paired.status()).toBe(201)
  const { token } = (await paired.json()) as { token: string }

  const revokedApi = await playwright.request.newContext({
    baseURL: BASE_URL,
    extraHTTPHeaders: { authorization: `Bearer ${token}` },
  })
  const phoneApi = await playwright.request.newContext({
    baseURL: BASE_URL,
    extraHTTPHeaders: { authorization: `Bearer ${seed.phone.token}` },
  })
  try {
    expect((await revokedApi.get('/v1/sync/state')).status()).toBe(200)

    await page.goto('/devices')
    await expect(page.getByRole('heading', { level: 1, name: 'Devices' })).toBeVisible()
    await page.getByRole('button', { name: `Revoke ${name}` }).click()

    const dialog = page.getByRole('dialog', { name: `Revoke ${name}?` })
    await expect(dialog).toBeVisible()
    await dialog.getByRole('button', { name: 'Revoke', exact: true }).click()

    await expect(dialog).toBeHidden()
    await expect(page.getByRole('row', { name: new RegExp(`${name}.*Revoked`) })).toBeVisible()

    expect((await revokedApi.get('/v1/sync/state')).status()).toBe(401)
    expect((await phoneApi.get('/v1/sync/state')).status()).toBe(200)
  } finally {
    await revokedApi.dispose()
    await phoneApi.dispose()
  }
})
