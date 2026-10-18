import { expect, test } from '@playwright/test'
import { blockingViolations, FIXED_NOW, screenshotDir } from './support'

const routes = [
  { path: '/login', slug: 'login' },
  { path: '/', slug: 'today' },
  { path: '/heart-rate', slug: 'heart-rate' },
  { path: '/stress', slug: 'stress' },
  { path: '/calories', slug: 'calories' },
  { path: '/history', slug: 'history' },
  { path: '/history/2026-10-07', slug: 'history-day' },
  { path: '/alarms', slug: 'alarms' },
  { path: '/webhooks', slug: 'webhooks' },
  // The front door endpoint in the fixtures (mocks/fixtures.ts HOOKS[0]).
  { path: '/webhooks/0196a7c2-3f1e-7d4a-9b1e-5c2f8a6d1e40', slug: 'webhook-deliveries' },
  { path: '/devices', slug: 'devices' },
  { path: '/sync', slug: 'sync' },
  { path: '/settings', slug: 'settings' },
  { path: '/integrations/whoop', slug: 'whoop' },
  { path: '/not-a-page', slug: 'not-found' },
] as const

const viewports = [
  { width: 1920, height: 1080 },
  { width: 390, height: 844 },
] as const

const schemes = ['light', 'dark'] as const

for (const route of routes) {
  for (const viewport of viewports) {
    for (const scheme of schemes) {
      test(`${route.path} at ${viewport.width}px, ${scheme}`, async ({ page }) => {
        await page.clock.setFixedTime(FIXED_NOW)
        await page.setViewportSize(viewport)
        await page.emulateMedia({ colorScheme: scheme })

        const response = await page.goto(route.path)
        expect(response?.ok()).toBe(true)
        await expect(page.getByRole('heading', { level: 1 })).toBeVisible()
        await page.evaluate(() => document.fonts.ready)

        const isDark = await page.evaluate(() => document.documentElement.classList.contains('dark'))
        expect(isDark).toBe(scheme === 'dark')

        const horizontalOverflow = await page.evaluate(
          () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
        )
        expect(horizontalOverflow).toBeLessThanOrEqual(0)

        expect(await blockingViolations(page)).toEqual([])

        // Only one screenshot size is kept: 1920x1080, light.
        if (viewport.width === 1920 && scheme === 'light') {
          await page.screenshot({ path: `${screenshotDir}${route.slug}.png`, animations: 'disabled' })
        }
      })
    }
  }
}
