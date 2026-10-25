// A throwaway receiver for the Health Relay schema (docs/schema.md): accepts
// a push, checks its shape, prints what it carries and answers as the schema
// says. It stores nothing unless --out is given. Any platform's app is tested
// against it; it proves the app assumes nothing about one destination.
//
//   node tools/receiver.mjs [--port 8787] [--host ::] [--token <bearer>] [--out <dir>] [--fail <status>]
//
// --token     require Authorization: Bearer <token> (401 otherwise)
// --out       write each accepted body to <dir>/<n>.json, as received
// --fail      answer every push with this status (to exercise an app's retry rules)
import { createServer } from 'node:http'
import { mkdirSync, writeFileSync } from 'node:fs'
import path from 'node:path'

const SCHEMA = 'apple-push/1'
const MAX_BYTES = 16 * 1024 * 1024
const MAX_DAYS = 62
const SECTIONS = ['stats', 'samples', 'workouts', 'summaries', 'ecg']

function args(argv) {
  const opts = { port: 8787, host: '::', token: process.env.RECEIVER_TOKEN || '', out: '', fail: 0 }
  for (let i = 0; i < argv.length; i++) {
    const key = argv[i].replace(/^--/, '')
    if (!(key in opts)) throw new Error(`unknown option ${argv[i]}`)
    opts[key] = typeof opts[key] === 'number' ? Number(argv[++i]) : argv[++i]
  }
  return opts
}

const isDay = (s) => typeof s === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(s)

/** The body's problems, or [] when it is a valid push. */
export function problems(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) return ['the body must be a JSON object']
  const out = []
  if (body.schema !== SCHEMA) out.push(`schema must be "${SCHEMA}"`)
  if (body.days !== undefined && !Array.isArray(body.days)) out.push('days must be an array')
  else if ((body.days || []).some((d) => !isDay(d))) out.push('days must be yyyy-MM-dd strings')
  else if ((body.days || []).length > MAX_DAYS) out.push(`at most ${MAX_DAYS} days per push`)
  for (const s of SECTIONS) if (body[s] !== undefined && !Array.isArray(body[s])) out.push(`${s} must be an array`)
  return out
}

/** Per-section counts, plus stats and samples by type. */
export function summarize(body) {
  const counts = Object.fromEntries(SECTIONS.map((s) => [s, (body[s] || []).length]))
  const byType = (rows) => rows.reduce((m, r) => ((m[r.type] = (m[r.type] || 0) + 1), m), {})
  return { counts, stats: byType(body.stats || []), samples: byType(body.samples || []) }
}

function main() {
  const opts = args(process.argv.slice(2))
  if (opts.out) mkdirSync(opts.out, { recursive: true })
  let n = 0
  const answer = (res, status, json) => {
    res.writeHead(status, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify(json))
  }
  const server = createServer((req, res) => {
    if (req.method !== 'POST') return answer(res, 405, { ok: false, error: 'POST a push' })
    if (opts.token && req.headers.authorization !== `Bearer ${opts.token}`) return answer(res, 401, { ok: false, error: 'token_unknown' })
    const chunks = []
    let size = 0
    req.on('data', (c) => {
      size += c.length
      if (size <= MAX_BYTES) chunks.push(c)
    })
    req.on('end', () => {
      const stamp = new Date().toISOString()
      if (size > MAX_BYTES) return answer(res, 413, { ok: false, error: 'too_large' })
      let body
      try {
        body = JSON.parse(Buffer.concat(chunks).toString('utf8'))
      } catch {
        return answer(res, 400, { ok: false, error: 'bad_push', message: 'the body is not JSON' })
      }
      const bad = problems(body)
      if (bad.length) {
        console.log(`${stamp} 400 ${bad.join('; ')}`)
        return answer(res, 400, { ok: false, error: 'bad_push', message: bad.join('; ') })
      }
      if (opts.fail) {
        console.log(`${stamp} ${opts.fail} (--fail)`)
        return answer(res, opts.fail, { ok: false, error: 'forced', message: `--fail ${opts.fail}` })
      }
      n++
      if (opts.out) writeFileSync(path.join(opts.out, `${String(n).padStart(4, '0')}.json`), Buffer.concat(chunks))
      const days = [...(body.days || [])].sort()
      const { counts, stats, samples } = summarize(body)
      const who = body.device ? `${body.device.name} (${body.device.app})` : 'unknown device'
      console.log(`${stamp} #${n} from ${who}: ${days.length ? `${days[0]}..${days[days.length - 1]} (${days.length} days)` : 'no days'}, ${Object.entries(counts).map(([k, v]) => `${k} ${v}`).join(', ')}`)
      for (const [type, c] of Object.entries({ ...stats, ...samples })) console.log(`    ${type} ${c}`)
      const range = days.length ? ` (${days[0]}${days.length > 1 ? ` to ${days[days.length - 1]}` : ''})` : ''
      const plural = (count, word) => `${count} ${word}${count === 1 ? '' : 's'}`
      const message = days.length
        ? `Received ${plural(days.length, 'day')}${range}: ${plural(counts.stats, 'stat')}, ${plural(counts.samples, 'sample')}, ${plural(counts.workouts, 'workout')}`
        : 'Connection OK'
      answer(res, 200, { ok: true, message, days: days.length, from: days[0] || null, to: days[days.length - 1] || null, ...counts })
    })
  })
  server.listen(opts.port, opts.host, () => console.log(`receiver listening on http://${opts.host.includes(':') ? `[${opts.host}]` : opts.host}:${opts.port}${opts.token ? ' (bearer required)' : ''}`))
}

if (import.meta.url === `file://${process.argv[1]}`) main()
