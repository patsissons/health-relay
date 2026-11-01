// The official MCP client against the app's server: connect, list the tools,
// call each one, and check a wrong token is refused. The server runs under
// `swift test` with synthetic data, over plain HTTP; TLS is covered by a UI test.
import { spawn } from 'node:child_process';
import { existsSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';

const port = 18840;
const stop = path.join(mkdtempSync(path.join(tmpdir(), 'hdr-mcp-')), 'stop');
const kit = fileURLToPath(new URL('../../ios/HealthDataRelayKit', import.meta.url));
const server = spawn('swift', ['test', '--filter', 'aServerForAClient'], { cwd: kit, env: { ...process.env, HDR_MCP_PORT: String(port), HDR_MCP_STOP: stop } });
server.stdout.resume();
server.stderr.resume();

const url = new URL(`http://127.0.0.1:${port}/mcp`);
async function until(ready) {
  for (let i = 0; i < 600; i++) {
    if (await ready()) return;
    await new Promise((ok) => setTimeout(ok, 200));
  }
  throw new Error('The server never came up');
}
await until(async () => {
  try {
    return (await fetch(url, { method: 'POST' })).status === 401;
  } catch {
    return false;
  }
});

const checks = {};
const refused = await fetch(url, { method: 'POST', headers: { Authorization: 'Bearer wrong' }, body: '{}' });
checks['a wrong token gets 401'] = refused.status === 401;

const client = new Client({ name: 'conformance', version: '1.0.0' });
const transport = new StreamableHTTPClientTransport(url, { requestInit: { headers: { Authorization: 'Bearer conformance-token' } } });
await client.connect(transport);
checks['connected as'] = client.getServerVersion()?.name === 'health-data-relay';
const { tools } = await client.listTools();
checks['eight tools'] = tools.length === 8;
for (const tool of tools) {
  const answer = await client.callTool({ name: tool.name, arguments: { start: '2026-10-20', end: '2026-10-25' } });
  const text = answer.content?.[0]?.text ?? '';
  let parsed = false;
  try {
    parsed = !!JSON.parse(text).data;
  } catch {}
  checks[`${tool.name} answers`] = !answer.isError && parsed;
}
await client.close();
writeFileSync(stop, '');
const code = await new Promise((ok) => server.on('close', ok));
checks['the server exited cleanly'] = code === 0;
console.log(checks);
process.exit(Object.values(checks).every(Boolean) ? 0 : 1);
