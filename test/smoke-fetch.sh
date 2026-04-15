#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PBM_BIN="$ROOT_DIR/zig-out/bin/pbm"
PORT="${PBM_SMOKE_PORT:-19122}"
URL="https://github.com/francescobianco/mush-demo"
SERVER_LOG="$(mktemp)"

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  rm -f "$SERVER_LOG"
}
trap cleanup EXIT

cd "$ROOT_DIR"

python3 -c '
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/api/fetch":
            self.send_response(404)
            self.end_headers()
            return

        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length).decode("utf-8")
        payload = json.loads(raw)
        response = {
            "status": "queued",
            "message": "mirror scheduled",
            "package": "mush-demo",
            "request_id": "req-smoke-001",
            "tarballs": 2,
            "url": payload.get("url", ""),
        }

        body = json.dumps(response).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass

HTTPServer(("127.0.0.1", int("'"$PORT"'")), Handler).serve_forever()
' >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

sleep 1

OUTPUT="$(PACKBASE_URL="http://127.0.0.1:$PORT" "$PBM_BIN" fetch "$URL")"

EXPECTED="$(cat <<EOF
fetch      mirror scheduled
source     $URL
package    mush-demo
status     queued
request    req-smoke-001
tarballs   2
EOF
)"

if [[ "$OUTPUT" != "$EXPECTED" ]]; then
  printf 'unexpected smoke output\n' >&2
  printf 'expected:\n%s\n' "$EXPECTED" >&2
  printf 'actual:\n%s\n' "$OUTPUT" >&2
  exit 1
fi

printf '%s\n' "$OUTPUT"
