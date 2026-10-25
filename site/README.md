# health-relay.lgtm.page

The product site and user docs: Astro Starlight, served by a Cloudflare
Worker with static assets (`wrangler.jsonc`, custom domain
`health-relay.lgtm.page`).

```sh
pnpm install
pnpm dev                 # copies ../docs into src/content/docs/reference, then serves
pnpm build
node scripts/og-image.mjs  # re-render public/og.png from the Status screenshot (needs Google Chrome)
pnpm run deploy          # needs CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID (../.env)
```

The reference pages are generated from `../docs/*.md` by
`scripts/sync-docs.mjs` on every dev and build; edit the files in `docs/`.
The screenshots in `src/assets/screenshots/` come from the iOS UI test
(`TEST_RUNNER_SCREENSHOTS`, see `../ios/README.md`).
