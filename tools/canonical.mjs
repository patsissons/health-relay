// Canonical JSON for the Health Relay schema: keys sorted at every level,
// no whitespace, slashes not escaped (JSON.stringify's own escaping). Every
// platform's encoder must produce these bytes for the same value.
//
//   node tools/canonical.mjs <file>           print the file's canonical form
//   node tools/canonical.mjs --check <file>…  exit 1 unless each file already is canonical
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

/** The value with every object's keys in sorted order (code unit order, as Array.sort). */
export function sortKeys(value) {
  if (Array.isArray(value)) return value.map(sortKeys)
  if (value && typeof value === 'object') {
    const out = {}
    for (const key of Object.keys(value).sort()) out[key] = sortKeys(value[key])
    return out
  }
  return value
}

export const canonical = (value) => JSON.stringify(sortKeys(value))

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2)
  const check = args[0] === '--check'
  const files = check ? args.slice(1) : args
  if (!files.length) {
    console.error('usage: node tools/canonical.mjs [--check] <file>…')
    process.exit(2)
  }
  let bad = 0
  for (const file of files) {
    const text = readFileSync(file, 'utf8')
    const want = canonical(JSON.parse(text))
    if (!check) process.stdout.write(want)
    else if (text !== want) {
      console.error(`${file}: not canonical`)
      bad++
    } else console.log(`${file}: canonical`)
  }
  process.exit(bad ? 1 : 0)
}
