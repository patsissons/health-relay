// Renders the site's Open Graph card (public/og.png, 1200x630) from the logo
// and the Status screenshot, with the installed Google Chrome:
//
//   node scripts/og-image.mjs
//
// Re-run it after replacing src/assets/screenshots/status.png.
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

const site = path.resolve(import.meta.dirname, '..')
const chrome = process.env.CHROME ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
const dataUrl = (file, type) => `data:${type};base64,${fs.readFileSync(file).toString('base64')}`

const logo = dataUrl(path.join(site, 'src/assets/logo.svg'), 'image/svg+xml')
const screenshot = dataUrl(path.join(site, 'src/assets/screenshots/status.png'), 'image/png')

const html = `<!doctype html>
<style>
  * { margin: 0; box-sizing: border-box; }
  body {
    width: 1200px; height: 630px; overflow: hidden; position: relative;
    font-family: -apple-system, 'SF Pro Display', 'Helvetica Neue', sans-serif; color: #ffe4e8;
    background:
      radial-gradient(circle at 12% 18%, rgb(255 69 97 / 0.38), transparent 45%),
      radial-gradient(circle at 92% 105%, rgb(249 120 52 / 0.32), transparent 50%),
      #170b0e;
  }
  .text { position: absolute; left: 72px; top: 72px; width: 600px; }
  .brand { display: flex; align-items: center; gap: 18px; font-size: 44px; font-weight: 700; color: #fff; }
  .brand img { width: 64px; height: 64px; }
  h1 { margin-top: 56px; font-size: 54px; line-height: 1.08; font-weight: 700; color: #fff; letter-spacing: -0.02em; }
  p { margin-top: 24px; font-size: 25px; line-height: 1.4; color: #ffc7cf; }
  .url { position: absolute; left: 72px; bottom: 64px; font-size: 22px; font-weight: 600; color: #ff8a9c; }
  .phone {
    position: absolute; right: 90px; top: 60px; width: 320px;
    border-radius: 44px; border: 10px solid #2a1a1e;
    box-shadow: 0 30px 80px -10px rgb(0 0 0 / 0.7);
  }
</style>
<div class="text">
  <div class="brand"><img src="${logo}">Health Relay</div>
  <h1>Your Apple Health data, delivered where you choose</h1>
  <p>Exact, incremental sync from your iPhone to your own destinations, in one open schema.</p>
</div>
<div class="url">health-relay.lgtm.page</div>
<img class="phone" src="${screenshot}">
`

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'og-'))
const page = path.join(dir, 'og.html')
fs.writeFileSync(page, html)
const out = path.join(site, 'public', 'og.png')
execFileSync(chrome, ['--headless=new', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=1',
  '--window-size=1200,630', `--screenshot=${out}`, `file://${page}`], { stdio: 'ignore' })
fs.rmSync(dir, { recursive: true })
console.log(`wrote ${path.relative(process.cwd(), out)}`)
