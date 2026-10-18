import { createHmac, randomUUID } from 'node:crypto'
import { expect, test, type Locator } from '@playwright/test'
import { BASE_URL } from './env'

// The value under a SecretView field label, e.g. "Signing secret".
async function fieldValue(scope: Locator, label: string): Promise<string> {
  const code = scope.locator(`xpath=.//p[normalize-space(.)="${label}"]/parent::div//code`)
  return (await code.innerText()).trim()
}

test('a webhook shows its secret once and accepts a correctly signed request', async ({ page, playwright }) => {
  const label = `E2E webhook ${Date.now()}`
  await page.goto('/webhooks')
  await expect(page.getByRole('heading', { level: 1, name: 'Webhooks' })).toBeVisible()

  // The empty state has a second button, so the header one comes first in the DOM.
  await page.getByRole('button', { name: 'New webhook' }).first().click()
  const form = page.getByRole('dialog', { name: 'New webhook' })
  await form.getByLabel('Label', { exact: true }).fill(label)
  await form.getByRole('button', { name: 'Create webhook' }).click()

  const created = page.getByRole('dialog', { name: `Webhook "${label}" created` })
  await expect(created).toBeVisible()
  const endpoint = await fieldValue(created, 'Endpoint')
  const secret = await fieldValue(created, 'Signing secret')
  expect(endpoint).toMatch(new RegExp(`^${BASE_URL}/v1/hooks/[^/]+$`))
  expect(secret.length).toBeGreaterThanOrEqual(32)
  await created.getByRole('button', { name: 'Done' }).click()
  await expect(created).toBeHidden()

  const body = JSON.stringify({ idempotency_key: `e2e-${randomUUID()}`, message: 'Garage door opened', channels: ['phone'] })
  const timestamp = Math.floor(Date.now() / 1000)
  // The HMAC key is the UTF-8 bytes of the secret string as shown (api-contract.md, Decisions).
  const signature = createHmac('sha256', secret).update(`${timestamp}.${body}`).digest('hex')
  const sender = await playwright.request.newContext()
  try {
    const response = await sender.post(endpoint, {
      headers: { 'content-type': 'application/json', 'x-icarus-signature': `t=${timestamp},v1=${signature}` },
      data: body,
    })
    expect(response.status()).toBe(202)
    expect(await response.json()).toEqual({ dispatch_id: expect.any(String) })
  } finally {
    await sender.dispose()
  }

  await page.getByRole('link', { name: `Deliveries for ${label}` }).click()
  await expect(page).toHaveURL(/\/webhooks\/[0-9a-f-]{36}$/)
  await expect(page.getByRole('cell', { name: 'Accepted', exact: true })).toBeVisible()
  await expect(page.getByRole('cell', { name: 'Valid', exact: true })).toBeVisible()

  // The secret is never shown again: not on the list, and not in the API.
  await page.goto('/webhooks')
  await expect(page.getByRole('cell', { name: label, exact: true })).toBeVisible()
  expect(await page.content()).not.toContain(secret)
  const response = await page.request.get('/v1/hooks')
  const { hooks } = (await response.json()) as { hooks: { label: string }[] }
  const hook = hooks.find((item) => item.label === label)
  expect(hook).toBeDefined()
  expect(hook).not.toHaveProperty('secret')
})
