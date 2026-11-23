#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECORDER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$RECORDER_DIR/.." && pwd)"
PLUGIN_BIN_DIR="$ROOT_DIR/plugin/bin"
APP_DIR="$PLUGIN_BIN_DIR/MeetingRecorder.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RES_DIR="$CONTENTS_DIR/Resources"
BUNDLE_ID="com.antigravity.meeting-recorder"

echo "[bundle-app] Building MeetingRecorder (release)..."
cd "$RECORDER_DIR"
swift build -c release --disable-sandbox

BIN_DIR="$(swift build -c release --disable-sandbox --show-bin-path)"
BIN_PATH="$BIN_DIR/MeetingRecorder"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "Error: compiled binary not found at $BIN_PATH" >&2
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"
cp "$BIN_PATH" "$MACOS_DIR/MeetingRecorder"
chmod +x "$MACOS_DIR/MeetingRecorder"

cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
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
  <string>0.3.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>26.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Antigravity Meeting 需要访问您的麦克风以录制会议语音并生成纪要。</string>
  <key>NSAudioCaptureUsageDescription</key>
  <string>Antigravity Meeting 需要捕获系统音频输出以实现双轨会议记录。</string>
</dict>
</plist>
EOF

SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Antigravity Meeting Local"'; then
    SIGN_IDENTITY="Antigravity Meeting Local"
  fi
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "[bundle-app] Signing with certificate identity: $SIGN_IDENTITY"
  codesign --force --deep --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP_DIR"
else
  echo "[bundle-app] Signing with ad-hoc identity (run setup-local-cert.sh to persist TCC across rebuilds)."
  codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP_DIR"
fi

echo "[bundle-app] Done: $APP_DIR"
