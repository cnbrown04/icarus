// Lyra lock (PLAN.md §13.2). Hashes the shadcn/Lyra-generated files so hand edits fail CI.
// Usage: node scripts/lyra-lock.mjs check | write
import { createHash } from 'node:crypto'
import { existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const webRoot = resolve(fileURLToPath(new URL('..', import.meta.url)))
const NOT_INITIALISED = 'Lyra not initialised yet (web/components.json is missing). Nothing to check.'

function walk(dir) {
  if (!existsSync(dir)) return []
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = join(dir, entry.name)
    return entry.isDirectory() ? walk(full) : [full]
  })
}

export function lyraFiles(root) {
  return [join(root, 'components.json'), join(root, 'src', 'index.css'), ...walk(join(root, 'src', 'components', 'ui'))]
    .filter((file) => existsSync(file))
    .map((file) => relative(root, file).split('\\').join('/'))
    .sort()
}

export function computeLock(root) {
  const files = {}
  for (const path of lyraFiles(root)) {
    files[path] = createHash('sha256').update(readFileSync(join(root, path))).digest('hex')
  }
  const combined = createHash('sha256')
    .update(Object.entries(files).map(([path, sha]) => `${path}\t${sha}\n`).join(''))
    .digest('hex')
  return { files, combined }
}

function check(root) {
  if (!existsSync(join(root, 'components.json'))) {
    console.log(NOT_INITIALISED)
    return 0
  }
  if (!existsSync(join(root, '.lyra-lock'))) {
    console.error('web/.lyra-lock is missing. Run pnpm lyra:lock after an intentional Lyra update.')
    return 1
  }
  const expected = JSON.parse(readFileSync(join(root, '.lyra-lock'), 'utf8'))
  const actual = computeLock(root)
  const changed = [...new Set([...Object.keys(expected.files), ...Object.keys(actual.files)])].filter(
    (path) => expected.files[path] !== actual.files[path],
  )
  if (changed.length === 0 && expected.combined === actual.combined) {
    console.log(`Lyra lock OK (${Object.keys(actual.files).length} files, ${actual.combined.slice(0, 12)})`)
    return 0
  }
  console.error('Lyra lock mismatch. Generated files changed:')
  for (const path of changed) console.error(`  ${path}`)
  console.error('Only "npx shadcn@latest apply --preset lyra" may change these. Then run pnpm lyra:lock.')
  return 1
}

function write(root) {
  if (!existsSync(join(root, 'components.json'))) {
    console.error(NOT_INITIALISED)
    return 1
  }
  const lock = computeLock(root)
  writeFileSync(join(root, '.lyra-lock'), `${JSON.stringify(lock, null, 2)}\n`)
  console.log(`Wrote web/.lyra-lock (${Object.keys(lock.files).length} files)`)
  return 0
}

const modes = { check, write }
const mode = process.argv[2]
if (!modes[mode]) {
  console.error('Usage: node scripts/lyra-lock.mjs check | write')
  process.exitCode = 2
} else {
  process.exitCode = modes[mode](webRoot)
}
