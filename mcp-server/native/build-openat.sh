#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT_PATH="$ROOT_DIR/plugin/bin/safe_openat.node"

mkdir -p "$(dirname "$OUT_PATH")"

NODE_INC="$(node -p 'const path = require("node:path"), fs = require("node:fs"); const candidates = [path.resolve(path.dirname(process.execPath), "../include/node"), "/opt/homebrew/include/node", "/usr/local/include/node"]; const hit = candidates.find((p) => fs.existsSync(path.join(p, "node_api.h"))); if (!hit) { process.exit(1); } hit')"

TMP_OBJ="$(mktemp "${TMPDIR:-/tmp}/safe_openat.XXXXXX.o")"
trap 'rm -f "$TMP_OBJ"' EXIT

cc -c -fPIC -O2 -Wall -Wextra -I"$NODE_INC" "$SCRIPT_DIR/safe_openat.c" -o "$TMP_OBJ"
swiftc -O -parse-as-library -emit-library "$SCRIPT_DIR/swift_u64.swift" "$TMP_OBJ" -Xlinker -undefined -Xlinker dynamic_lookup -o "$OUT_PATH"
codesign --force --sign - "$OUT_PATH" >/dev/null 2>&1 || true

echo "[build-native] Built $OUT_PATH"
