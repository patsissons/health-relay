// Runs fixtures/templates/conformance.json through liquidjs. The Swift tests
// run the same file, so a case passing in both means our subset agrees with
// a real Liquid implementation.
import { readFileSync } from 'node:fs';
import { Liquid } from 'liquidjs';

const { cases } = JSON.parse(readFileSync(new URL('../../fixtures/templates/conformance.json', import.meta.url)));
let failed = 0;
for (const c of cases) {
  const engine = new Liquid({ timezoneOffset: c.tz === undefined ? 0 : -c.tz });
  let got;
  try {
    got = await engine.parseAndRender(c.t, c.data ?? {});
  } catch (e) {
    got = `ERROR ${e.message}`;
  }
  const want = c.want;
  const same = c.skipSpaces ? got.replace(/\s/g, '') === want.replace(/\s/g, '') : got === want;
  if (!same) {
    failed++;
    console.log(`FAIL ${JSON.stringify(c.t)}\n  want ${JSON.stringify(want)}\n  got  ${JSON.stringify(got)}`);
  }
}
console.log(`${cases.length - failed}/${cases.length} agree with liquidjs`);
process.exit(failed ? 1 : 0);
