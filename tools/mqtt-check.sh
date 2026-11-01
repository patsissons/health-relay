#!/bin/sh
# Publishes through the app's MQTT client to a real broker and reads it back.
# Needs Docker. Run from anywhere: tools/mqtt-check.sh
set -e
name=hdr-mosquitto-check
conf=$(mktemp)
printf 'listener 1883\nallow_anonymous true\n' > "$conf"
docker rm -f "$name" >/dev/null 2>&1 || true
docker run -d --rm --name "$name" -p 18830:1883 -v "$conf:/mosquitto/config/mosquitto.conf" eclipse-mosquitto:2.0.20 >/dev/null
trap 'docker rm -f "$name" >/dev/null 2>&1; rm -f "$conf"' EXIT
sleep 2
cd "$(dirname "$0")/../ios/HealthDataRelayKit"
HDR_MQTT_HOST=127.0.0.1 HDR_MQTT_PORT=18830 swift test --filter RealBrokerTests 2>&1 | grep -E "Test run with|recorded an issue|error:"
# Retained, so a subscriber arriving now still gets all three.
docker exec "$name" mosquitto_sub -t 'hdr/check/#' -v -W 2 -C 3
