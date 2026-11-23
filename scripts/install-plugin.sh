#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_PLUGIN="$ROOT_DIR/plugin"
SKIP_BUILD=false
DEST_PLUGIN="$HOME/.gemini/config/plugins/anti-meeting"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      SKIP_BUILD=true
      shift
      ;;
    --dest)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "Error: --dest requires a non-empty path" >&2
        exit 2
      fi
      DEST_PLUGIN="$2"
      shift 2
      ;;
    --dest=*)
      DEST_PLUGIN="${1#--dest=}"
      if [[ -z "$DEST_PLUGIN" ]]; then
        echo "Error: --dest requires a non-empty path" >&2
        exit 2
      fi
      shift
      ;;
    *)
      echo "Error: unknown argument '$1'. Allowed flags: --skip-build, --dest <path>" >&2
      exit 2
      ;;
  esac
done

abs_path() {
  python3 -c 'import os, sys; print(os.path.realpath(os.path.abspath(sys.argv[1])))' "$1"
}

SRC_REAL="$(abs_path "$SRC_PLUGIN")"
ROOT_REAL="$(abs_path "$ROOT_DIR")"
DEST_PARENT_RAW="$(dirname "$DEST_PLUGIN")"
DEST_BASE="$(basename "$DEST_PLUGIN")"

if [[ -z "$DEST_PLUGIN" || "$DEST_PLUGIN" == "/" || "$DEST_PARENT_RAW" == "/" ]]; then
  echo "Error: refusing unsafe destination path '$DEST_PLUGIN'" >&2
  exit 2
fi

if [[ "$DEST_BASE" != "anti-meeting" ]]; then
  echo "Error: destination directory basename must be 'anti-meeting', got '$DEST_BASE'" >&2
  exit 2
fi

mkdir -p "$DEST_PARENT_RAW"
DEST_PARENT_REAL="$(abs_path "$DEST_PARENT_RAW")"
DEST_REAL="$DEST_PARENT_REAL/$DEST_BASE"

if [[ "$DEST_REAL" == "$SRC_REAL" || "$DEST_REAL" == "$ROOT_REAL" || "$DEST_REAL" == "$ROOT_REAL"/* || "$ROOT_REAL" == "$DEST_REAL"/* ]]; then
  echo "Error: destination '$DEST_REAL' overlaps source repository '$ROOT_REAL'" >&2
  exit 2
fi

if [[ -e "$DEST_REAL" ]]; then
  if [[ -L "$DEST_REAL" || ! -d "$DEST_REAL" ]]; then
    echo "Error: existing destination '$DEST_REAL' is not a real directory" >&2
    exit 2
  fi
  if [[ -n "$(ls -A "$DEST_REAL")" && ! -f "$DEST_REAL/plugin.json" ]]; then
    echo "Error: non-empty destination '$DEST_REAL' does not look like an existing anti-meeting plugin (missing plugin.json)" >&2
    exit 2
  fi
fi

if [[ "$SKIP_BUILD" != "true" ]]; then
  echo "[install-plugin] Building UI, MCP server, and MeetingRecorder.app..."
  npm --prefix "$ROOT_DIR" run build
fi

if [[ "$(basename "$DEST_PARENT_REAL")" == "plugins" && -w "$(dirname "$DEST_PARENT_REAL")" ]]; then
  STAGING_DIR="$(dirname "$DEST_PARENT_REAL")/.anti-meeting.staging.$$"
else
  STAGING_DIR="$DEST_PARENT_REAL/.anti-meeting.staging.$$"
fi

cleanup_on_error() {
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    rm -rf "$STAGING_DIR" || true
  fi
}
trap cleanup_on_error EXIT

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
ditto "$SRC_REAL" "$STAGING_DIR"

for required in \
  "plugin.json" \
  "mcp_config.json" \
  "bin/meeting-mcp-server.mjs" \
  "bin/safe_openat.node" \
  "bin/MeetingRecorder.app/Contents/MacOS/MeetingRecorder" \
  "ui/app.html" \
  "skills/meeting-notes/SKILL.md"
do
  if [[ ! -e "$STAGING_DIR/$required" ]]; then
    echo "Error: staged plugin missing required file '$required'" >&2
    exit 1
  fi
done

echo "[install-plugin] Installing plugin atomically to $DEST_REAL..."
python3 - "$STAGING_DIR" "$DEST_REAL" <<'PYEOF'
import ctypes
import errno
import os
import sys

staging = sys.argv[1]
dest = sys.argv[2]

RENAME_SWAP = 0x00000002
RENAME_EXCL = 0x00000004

libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
renamex_np = libc.renamex_np
renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
renamex_np.restype = ctypes.c_int

def call_renamex(src_path: str, dst_path: str, flags: int) -> int:
    ctypes.set_errno(0)
    rc = renamex_np(os.fsencode(src_path), os.fsencode(dst_path), flags)
    return 0 if rc == 0 else ctypes.get_errno()

if os.path.lexists(dest):
    if os.path.islink(dest) or not os.path.isdir(dest):
        sys.stderr.write(f"Error: destination '{dest}' is not a real directory\n")
        sys.exit(2)
    err = call_renamex(staging, dest, RENAME_SWAP)
    if err == errno.ENOENT:
        err = call_renamex(staging, dest, RENAME_EXCL)
else:
    err = call_renamex(staging, dest, RENAME_EXCL)
    if err == errno.EEXIST:
        if os.path.islink(dest) or not os.path.isdir(dest):
            sys.stderr.write(f"Error: destination '{dest}' is not a real directory\n")
            sys.exit(2)
        err = call_renamex(staging, dest, RENAME_SWAP)

if err != 0:
    sys.stderr.write(f"Error: atomic plugin swap failed ({err}: {os.strerror(err)})\n")
    sys.exit(1)
PYEOF

rm -rf "$STAGING_DIR"

echo "[install-plugin] Installed files:"
find "$DEST_REAL" -maxdepth 3 | sort

DEFAULT_PROD_DEST="$(abs_path "$HOME/.gemini/config/plugins/anti-meeting")"
PROD_SOCK="$HOME/.gemini/antigravity/plugin_data/anti-meeting/run/recorder.sock"
if [[ "$DEST_REAL" == "$DEFAULT_PROD_DEST" && -S "$PROD_SOCK" ]]; then
  python3 - "$PROD_SOCK" <<'PYEOF'
import json
import socket
import sys

sock_path = sys.argv[1]
try:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(1.0)
        s.connect(sock_path)
        s.sendall(b"GET /v1/health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        raw = b""
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            raw += chunk
    body = raw.split(b"\r\n\r\n", 1)[1] if b"\r\n\r\n" in raw else b""
    health = json.loads(body.decode("utf-8"))
    state = health.get("state")
    pid = health.get("pid")
    if state in ("idle", "error"):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(1.0)
            s.connect(sock_path)
            s.sendall(b"POST /v1/app/quit HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            s.recv(4096)
        print(f"[install-plugin] Gracefully stopped stale idle MeetingRecorder daemon (pid={pid}) so new bundle takes effect.")
    else:
        print(f"[install-plugin] Leaving active MeetingRecorder daemon running (pid={pid}, state={state}).")
except Exception:
    pass
PYEOF
fi

if [[ "$DEST_REAL" == "$DEFAULT_PROD_DEST" && -n "${ANTIGRAVITY_CSRF_TOKEN:-}" ]]; then
  LS_ADDR="${ANTIGRAVITY_LS_ADDRESS:-localhost:5387}"
  if curl -sf --max-time 5 \
    -H "Content-Type: application/json" \
    -H "x-codeium-csrf-token: ${ANTIGRAVITY_CSRF_TOKEN}" \
    -d '{"serverName":"anti-meeting_recorder"}' \
    "http://${LS_ADDR}/exa.language_server_pb.LanguageServerService/RefreshMcpServers" >/dev/null 2>&1; then
    echo "[install-plugin] Refreshed live MCP server anti-meeting_recorder via LanguageServer."
  else
    echo "[install-plugin] Warning: failed to refresh anti-meeting_recorder via LanguageServer; reload MCP server in settings if already running." >&2
  fi
fi
