import { mkdirSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import AxeBuilder from '@axe-core/playwright'
import type { Page } from '@playwright/test'
import { MOCK_NOW } from '../../src/mocks/fixtures'

// The page clock and the mocks share one instant, so the same route always renders the same pixels.
export const FIXED_NOW = new Date(MOCK_NOW)

export const screenshotDir = fileURLToPath(new URL('../../test-results/screenshots/', import.meta.url))
mkdirSync(screenshotDir, { recursive: true })

// Serious and critical axe violations fail the test. Run it with any dialog open, not only on the page.
export async function blockingViolations(page: Page): Promise<string[]> {
  const results = await new AxeBuilder({ page }).analyze()
  return results.violations
    .filter((violation) => violation.impact === 'serious' || violation.impact === 'critical')
    .map(
      (violation) =>
        `${violation.id} (${violation.impact}): ${violation.help} [${violation.nodes.map((node) => node.target.join(' ')).join(' | ')}]`,
    )
}
