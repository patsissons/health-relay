// Copies the repo's platform-neutral docs (../docs) into the site's
// reference section, so the schema has one source. Each file's first
// heading becomes its title; links to sibling docs become site links and
// links elsewhere in the repo become GitHub links.
import { readFileSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const docs = path.join(here, '..', '..', 'docs')
const out = path.join(here, '..', 'src', 'content', 'docs', 'reference')
const repo = 'https://github.com/patsissons/health-relay/blob/main'

const pages = [
  { file: 'schema.md', slug: 'schema', title: 'The schema', order: 1, description: 'The apple-push/1 body every platform sends and every receiver accepts.' },
  { file: 'design.md', slug: 'behaviour', title: 'Behaviour', order: 2, description: 'Which days are sent, batching, retries and triggers, on every platform.' },
  { file: 'receivers.md', slug: 'receivers', title: 'Writing a receiver', order: 3, description: 'What an HTTP endpoint needs to accept Health Relay pushes.' },
]
const slugOf = Object.fromEntries(pages.map((p) => [p.file, p.slug]))

function rewrite(markdown) {
  return markdown.replace(/\]\(([^)\s]+)\)/g, (whole, target) => {
    if (/^(https?:|#|mailto:)/.test(target)) return whole
    const [file, anchor] = target.split('#')
    const hash = anchor ? `#${anchor}` : ''
    if (slugOf[file]) return `](/reference/${slugOf[file]}/${hash})`
    const resolved = path.posix.normalize(path.posix.join('docs', file))
    return `](${repo}/${resolved}${hash})`
  })
}

for (const p of pages) {
  const source = readFileSync(path.join(docs, p.file), 'utf8')
  // The page title comes from the frontmatter; drop the document's own H1.
  const body = rewrite(source.replace(/^# .*\n+/, ''))
  const front = [
    '---',
    `title: ${p.title}`,
    `description: ${p.description}`,
    `sidebar:`,
    `  order: ${p.order}`,
    `editUrl: https://github.com/patsissons/health-relay/edit/main/docs/${p.file}`,
    '---',
    '',
    `<!-- Generated from docs/${p.file} by scripts/sync-docs.mjs; edit that file. -->`,
    '',
  ].join('\n')
  writeFileSync(path.join(out, `${p.slug}.md`), front + body)
}
console.log(`synced ${pages.length} docs into src/content/docs/reference`)
