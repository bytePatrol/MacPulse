#!/bin/bash
# Builds MacPulse.app, confirms it stays up, then quits it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

./scripts/build-app.sh

APP="$ROOT/build/MacPulse.app"
if [[ ! -x "$APP/Contents/MacOS/MacPulse" ]]; then
    echo "smoke-test: built app is missing an executable" >&2
    exit 1
fi

pid=""
cleanup() {
    if [[ -n "${pid}" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        sleep 0.4
        kill -9 "$pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT

before="$(pgrep -x MacPulse | sort -u || true)"
open "$APP"

for _ in $(seq 1 25); do
    while IFS= read -r candidate; do
        [[ -z "$candidate" ]] && continue
        if [[ -z "$before" ]] || ! grep -qx "$candidate" <<<"$before"; then
            pid="$candidate"
            break
        fi
    done < <(pgrep -x MacPulse || true)
    [[ -n "$pid" ]] && break
    sleep 0.2
done

if [[ -z "$pid" ]]; then
    echo "smoke-test: MacPulse did not start" >&2
    exit 1
fi

sleep 6

if ! kill -0 "$pid" 2>/dev/null; then
    echo "smoke-test: MacPulse (pid $pid) exited before 6 seconds" >&2
    pid=""
    exit 1
fi

kill "$pid" 2>/dev/null || true
for _ in $(seq 1 20); do
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "smoke-test: MacPulse (pid $pid) stayed alive for 6s and then quit"
        pid=""
        exit 0
    fi
    sleep 0.25
done

echo "smoke-test: MacPulse (pid $pid) ignored SIGTERM" >&2
exit 1
