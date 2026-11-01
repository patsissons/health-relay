// A real MQTT broker for the app's client to publish to, then a check of what
// arrived, including authentication. tools/mqtt-check.sh does the same with
// Mosquitto when Docker is available.
import { createServer } from 'node:net';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import aedes from 'aedes';

const broker = aedes();
const seen = [];
broker.on('publish', (packet, client) => {
  if (client) seen.push({ topic: packet.topic, payload: packet.payload.toString(), qos: packet.qos, retain: packet.retain });
});
const server = createServer(broker.handle);
await new Promise((ok) => server.listen(18830, '127.0.0.1', ok));

const kit = fileURLToPath(new URL('../../ios/HealthDataRelayKit', import.meta.url));
const test = spawn('swift', ['test', '--filter', 'RealBrokerTests'], { cwd: kit, env: { ...process.env, HDR_MQTT_HOST: '127.0.0.1', HDR_MQTT_PORT: '18830' } });
let log = '';
test.stdout.on('data', (d) => (log += d));
test.stderr.on('data', (d) => (log += d));
const code = await new Promise((ok) => test.on('close', ok));

const want = [0, 1, 2];
const missing = want.filter((qos) => !seen.some((m) => m.topic === `hdr/check/${qos}` && m.qos === qos && m.retain && m.payload === `qos ${qos}`));
console.log(seen);
console.log(log.split('\n').filter((l) => /Test run with|recorded an issue|error:/.test(l)).join('\n'));
broker.close();
server.close();
if (code !== 0 || missing.length) {
  console.log(`FAILED: exit ${code}, missing qos ${missing}`);
  process.exit(1);
}
console.log('The broker received all three, at the right QoS and retained.');
process.exit(0);
