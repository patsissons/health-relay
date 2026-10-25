import starlight from '@astrojs/starlight'
import { defineConfig } from 'astro/config'
import starlightLinksValidator from 'starlight-links-validator'
import starlightLlmsTxt from 'starlight-llms-txt'

const site = 'https://health-relay.lgtm.page'
const repo = 'https://github.com/patsissons/health-relay'
const meta = (property, content) => ({ tag: 'meta', attrs: { property, content } })

export default defineConfig({
  site,
  integrations: [
    starlight({
      title: 'Health Relay',
      description: 'Relay Apple Health to destinations you choose, exactly and incrementally, in one open schema.',
      logo: { src: './src/assets/logo.svg' },
      favicon: '/favicon.svg',
      customCss: ['./src/styles/custom.css'],
      head: [
        meta('og:image', `${site}/og.png`),
        meta('og:image:width', '1200'),
        meta('og:image:height', '630'),
        meta('og:image:alt', 'Health Relay: your Apple Health data, delivered where you choose'),
      ],
      social: [{ icon: 'github', label: 'GitHub', href: repo }],
      editLink: { baseUrl: `${repo}/edit/main/site/` },
      lastUpdated: true,
      plugins: [
        starlightLinksValidator(),
        // /llms.txt, /llms-full.txt and /llms-small.txt, generated from these docs
        starlightLlmsTxt({
          projectName: 'Health Relay',
          description:
            'Health Relay is an iPhone app that reads Apple Health and delivers each day, exactly and incrementally, to HTTP endpoints the user configures, as JSON in the open `apple-push/1` schema.',
          details: [
            '- A receiver is any HTTP endpoint that accepts `POST` of the schema and answers 2xx; an empty push (`days: []`) is the connection test.',
            '- Every day listed in `days` is described in full, so a receiver replaces what it holds for those days.',
            `- Source code, fixtures and a reference receiver: ${repo}`,
          ].join('\n'),
          promote: ['index', 'getting-started/**', 'reference/schema'],
        }),
      ],
      sidebar: [
        { label: 'Getting started', items: [{ autogenerate: { directory: 'getting-started' } }] },
        { label: 'Guides', items: [{ autogenerate: { directory: 'guides' } }] },
        { label: 'Reference', items: [{ autogenerate: { directory: 'reference' } }] },
      ],
    }),
  ],
})
