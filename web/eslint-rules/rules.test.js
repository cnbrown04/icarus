import { RuleTester } from 'eslint'
import { describe, it } from 'vitest'
import icarus from './index.js'

RuleTester.describe = describe
RuleTester.it = it

const tester = new RuleTester({
  languageOptions: {
    ecmaVersion: 'latest',
    sourceType: 'module',
    parserOptions: { ecmaFeatures: { jsx: true } },
  },
})

tester.run('no-rounded', icarus.rules['no-rounded'], {
  valid: [
    { code: '<div className="flex border p-4 bg-white" />' },
    { code: 'const style = { color: "red", padding: 4 }' },
    { code: '<div className="grid-cols-[1fr_2fr] overflow-hidden" />' },
  ],
  invalid: [
    { code: '<div className="rounded-md" />', errors: [{ messageId: 'utility' }] },
    { code: '<div className="p-4 md:rounded-lg" />', errors: [{ messageId: 'utility' }] },
    { code: '<div className="!rounded-sm" />', errors: [{ messageId: 'utility' }] },
    { code: '<div className="rounded" />', errors: [{ messageId: 'utility' }] },
    { code: '<div className={`p-4 ${big ? "rounded-full" : ""}`} />', errors: [{ messageId: 'utility' }] },
    { code: '<div className={`p-4 rounded-xl`} />', errors: [{ messageId: 'utility' }] },
    { code: 'const style = { borderRadius: 4 }', errors: [{ messageId: 'inline' }] },
    { code: 'const style = { "border-top-left-radius": 4 }', errors: [{ messageId: 'inline' }] },
    { code: 'const style = { borderTopLeftRadius: 4 }', errors: [{ messageId: 'inline' }] },
  ],
})

tester.run('no-arbitrary-spacing', icarus.rules['no-arbitrary-spacing'], {
  valid: [
    { code: '<div className="p-4 gap-3 mt-6 w-[320px]" />' },
    { code: '<div className="md:px-6 space-y-2 h-12" />' },
    { code: 'const x = "text-[13px]"' },
  ],
  invalid: [
    { code: '<div className="p-[13px]" />', errors: [{ messageId: 'arbitrary', data: { token: 'p-[13px]' } }] },
    { code: '<div className="mt-[7px] p-4" />', errors: [{ messageId: 'arbitrary', data: { token: 'mt-[7px]' } }] },
    { code: '<div className="gap-[10px]" />', errors: [{ messageId: 'arbitrary', data: { token: 'gap-[10px]' } }] },
    { code: '<div className="-mx-[3px]" />', errors: [{ messageId: 'arbitrary', data: { token: '-mx-[3px]' } }] },
    { code: '<div className="md:px-[5px]" />', errors: [{ messageId: 'arbitrary', data: { token: 'md:px-[5px]' } }] },
    { code: '<div className="space-y-[3px]" />', errors: [{ messageId: 'arbitrary', data: { token: 'space-y-[3px]' } }] },
  ],
})

tester.run('no-emoji-jsx', icarus.rules['no-emoji-jsx'], {
  valid: [
    { code: '<p>62 bpm</p>' },
    { code: 'const label = "Pair iPhone"' },
    { code: '<p>{"No data yet"}</p>' },
  ],
  invalid: [
    { code: '<p>Synced 🎉</p>', errors: [{ messageId: 'emoji' }] },
    { code: 'const status = "✅ connected"', errors: [{ messageId: 'emoji' }] },
    { code: 'const toast = `done 🚀 ${count}`', errors: [{ messageId: 'emoji' }] },
  ],
})
