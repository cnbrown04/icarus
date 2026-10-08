import js from '@eslint/js'
import globals from 'globals'
import tseslint from 'typescript-eslint'
import reactHooks from 'eslint-plugin-react-hooks'
import icarus from './eslint-rules/index.js'

export default tseslint.config(
  { ignores: ['dist', 'node_modules', 'test-results', 'playwright-report'] },
  js.configs.recommended,
  tseslint.configs.recommended,
  {
    files: ['**/*.{ts,tsx,js,mjs}'],
    languageOptions: { globals: { ...globals.browser, ...globals.node } },
  },
  {
    files: ['src/**/*.{ts,tsx}'],
    ...reactHooks.configs.flat.recommended,
  },
  {
    // Design rules (PLAN.md §13.2, §15.5). Lyra-generated components/ui is exempt from the shape rules.
    files: ['src/**/*.{ts,tsx}'],
    plugins: { icarus },
    rules: {
      'icarus/no-emoji-jsx': 'error',
    },
  },
  {
    files: ['src/**/*.{ts,tsx}'],
    ignores: ['src/components/ui/**'],
    plugins: { icarus },
    rules: {
      'icarus/no-rounded': 'error',
      'icarus/no-arbitrary-spacing': 'error',
    },
  },
)
