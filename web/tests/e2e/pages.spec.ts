import { mkdirSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import AxeBuilder from '@axe-core/playwright'
import { expect, test } from '@playwright/test'

const routes = [
  { path: '/login', slug: 'login' },
  { path: '/', slug: 'today' },
  { path: '/heart-rate', slug: 'heart-rate' },
  { path: '/stress', slug: 'stress' },
  { path: '/calories', slug: 'calories' },
  { path: '/history', slug: 'history' },
  { path: '/alarms', slug: 'alarms' },
  { path: '/webhooks', slug: 'webhooks' },
  { path: '/devices', slug: 'devices' },
  { path: '/sync', slug: 'sync' },
  { path: '/settings', slug: 'settings' },
  { path: '/not-a-page', slug: 'not-found' },
] as const

const viewports = [
  { width: 1920, height: 1080 },
  { width: 390, height: 844 },
] as const

const schemes = ['light', 'dark'] as const

const screenshotDir = fileURLToPath(new URL('../../test-results/screenshots/', import.meta.url))
mkdirSync(screenshotDir, { recursive: true })

for (const route of routes) {
  for (const viewport of viewports) {
    for (const scheme of schemes) {
      test(`${route.path} at ${viewport.width}px, ${scheme}`, async ({ page }) => {
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

        const results = await new AxeBuilder({ page }).analyze()
        const blocking = results.violations
          .filter((violation) => violation.impact === 'serious' || violation.impact === 'critical')
          .map((violation) => `${violation.id} (${violation.impact}): ${violation.help}`)
        expect(blocking).toEqual([])

        // Only one screenshot size is kept: 1920x1080, light (Caleb's request, 2026-10-08).
        if (viewport.width === 1920 && scheme === 'light') {
          await page.screenshot({ path: `${screenshotDir}${route.slug}.png` })
        }
      })
    }
  }
}
