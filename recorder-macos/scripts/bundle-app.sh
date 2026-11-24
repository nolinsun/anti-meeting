#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECORDER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$RECORDER_DIR/.." && pwd)"
APP_DIR="${OUT_APP_DIR:-$ROOT_DIR/plugin/bin/MeetingRecorder.app}"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RES_DIR="$CONTENTS_DIR/Resources"
BUNDLE_ID="io.github.nolinsun.meeting-recorder"

echo "[bundle-app] Building MeetingRecorder (release)..."
cd "$RECORDER_DIR"
BUILD_ARGS=(-c release --disable-sandbox)
if [[ -n "${SWIFT_SCRATCH_PATH:-}" ]]; then
  BUILD_ARGS+=(--scratch-path "$SWIFT_SCRATCH_PATH")
fi
swift build "${BUILD_ARGS[@]}"

BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
BIN_PATH="$BIN_DIR/MeetingRecorder"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "Error: compiled binary not found at $BIN_PATH" >&2
  exit 1
fi

STAGING_APP="${APP_DIR}.staging.$$"
rm -rf "$STAGING_APP"
mkdir -p "$STAGING_APP/Contents/MacOS" "$STAGING_APP/Contents/Resources"
cp "$BIN_PATH" "$STAGING_APP/Contents/MacOS/MeetingRecorder"
chmod +x "$STAGING_APP/Contents/MacOS/MeetingRecorder"

cat > "$STAGING_APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>MeetingRecorder</string>
  <key>CFBundleExecutable</key>
  <string>MeetingRecorder</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>MeetingRecorder</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.4.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.2</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Meeting Notes needs microphone access to record meetings and generate structured notes.</string>
  <key>NSAudioCaptureUsageDescription</key>
  <string>Meeting Notes needs system audio capture access to record remote meeting participants.</string>
</dict>
</plist>
EOF

SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Local Meeting Recorder"'; then
    SIGN_IDENTITY="Local Meeting Recorder"
  fi
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "[bundle-app] Signing with certificate identity: $SIGN_IDENTITY"
  codesign --force --deep --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$STAGING_APP"
else
  echo "[bundle-app] Signing with ad-hoc identity (run setup-local-cert.sh to persist TCC across rebuilds)."
  codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$STAGING_APP"
fi

mkdir -p "$(dirname "$APP_DIR")"
rm -rf "$APP_DIR"
mv "$STAGING_APP" "$APP_DIR"

echo "[bundle-app] Done: $APP_DIR"
