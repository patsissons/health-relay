// A real SMTP server for the app's client: STARTTLS and a password, then a check
// that what arrived parses as a mail message with its attachment intact.
import { spawn, execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { SMTPServer } from 'smtp-server';

const dir = mkdtempSync(path.join(tmpdir(), 'hdr-smtp-'));
const key = path.join(dir, 'key.pem');
const cert = path.join(dir, 'cert.pem');
execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', key, '-out', cert, '-subj', '/CN=127.0.0.1', '-days', '1'], { stdio: 'ignore' });

let received = '';
let authed = false;
let secure = false;
const server = new SMTPServer({
  key: readFileSync(key),
  cert: readFileSync(cert),
  allowInsecureAuth: false,
  onAuth(auth, session, cb) {
    secure = session.secure;
    if (auth.username === 'me' && auth.password === 'secret') {
      authed = true;
      return cb(null, { user: 'me' });
    }
    cb(new Error('bad credentials'));
  },
  onData(stream, session, cb) {
    stream.on('data', (d) => (received += d));
    stream.on('end', cb);
  },
});
await new Promise((ok) => server.listen(18825, '127.0.0.1', ok));

const kit = fileURLToPath(new URL('../../ios/HealthDataRelayKit', import.meta.url));
const test = spawn('swift', ['test', '--filter', 'aRealServer'], { cwd: kit, env: { ...process.env, HDR_SMTP_PORT: '18825' } });
let log = '';
test.stdout.on('data', (d) => (log += d));
test.stderr.on('data', (d) => (log += d));
const code = await new Promise((ok) => test.on('close', ok));
server.close();

const attachment = Buffer.from('date,steps\n2026-10-25,100\n').toString('base64');
const checks = { 'test passed': code === 0, 'signed in': authed, 'over TLS': secure, 'has the attachment': received.includes(attachment), 'is multipart': received.includes('multipart/mixed') };
console.log(log.split('\n').filter((l) => /Test run with|recorded an issue|error:/.test(l)).join('\n'));
console.log(checks);
process.exit(Object.values(checks).every(Boolean) ? 0 : 1);
