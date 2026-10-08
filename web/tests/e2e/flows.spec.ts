import { expect, test } from '@playwright/test'
import { blockingViolations, FIXED_NOW, screenshotDir } from './support'

// Dialogs and sheets open: axe runs with them on screen, and the screenshots show them.
test.beforeEach(async ({ page }) => {
  await page.clock.setFixedTime(FIXED_NOW)
  await page.setViewportSize({ width: 1920, height: 1080 })
})

for (const scheme of ['light', 'dark'] as const) {
  test(`alarm editor sheet, ${scheme}`, async ({ page }) => {
    await page.emulateMedia({ colorScheme: scheme })
    await page.goto('/alarms')
    await expect(page.getByRole('heading', { level: 1, name: 'Alarms' })).toBeVisible()

    await page.getByRole('button', { name: 'New alarm' }).click()
    const sheet = page.getByRole('dialog', { name: 'New alarm' })
    await expect(sheet).toBeVisible()
    await page.evaluate(() => document.fonts.ready)

    expect(await blockingViolations(page)).toEqual([])
    if (scheme === 'light') {
      await page.screenshot({ path: `${screenshotDir}alarm-editor.png`, animations: 'disabled' })
    }
  })

  test(`secret dialog after creating a webhook, ${scheme}`, async ({ page }) => {
    await page.emulateMedia({ colorScheme: scheme })
    await page.goto('/webhooks')
    await expect(page.getByRole('heading', { level: 1, name: 'Webhooks' })).toBeVisible()

    await page.getByRole('button', { name: 'New webhook' }).click()
    await page.getByLabel('Label').fill('Garage door')
    await page.getByRole('button', { name: 'Create webhook' }).click()

    const dialog = page.getByRole('dialog', { name: 'Webhook "Garage door" created' })
    await expect(dialog).toBeVisible()
    await page.evaluate(() => document.fonts.ready)

    expect(await blockingViolations(page)).toEqual([])
    if (scheme === 'light') {
      await page.screenshot({ path: `${screenshotDir}webhook-created.png`, animations: 'disabled' })
    }
  })
}
