# anti-meeting

[简体中文](README.md) | **English**

> A **macOS-only** local meeting recorder, dual-track speaker timeline generator, and structured Markdown meeting notes plugin (MCP App + Skill + Native Swift Recorder) for **Google Antigravity**.

> [!IMPORTANT]
> **macOS Only**
> This project **only supports macOS — Windows and Linux are not supported**. Its audio capture, background daemon, and atomic file safety rely directly on macOS system APIs:
> - Dual-track system audio and microphone capture is built on **macOS Core Audio Process Tap**, **AVFoundation**, and **Swift 6.2**;
> - The native file locking and atomic swap addon relies on macOS syscalls (`renamex_np`, `openat`, `flock`) and the Xcode toolchain (`cc`, `swiftc`, `codesign`).

---

## Requirements

- **Operating System**: macOS 26.0 or later (matching [recorder-macos/Package.swift](recorder-macos/Package.swift) and [bundle-app.sh](recorder-macos/scripts/bundle-app.sh))
- **Build Toolchain**: Xcode Command Line Tools (including Swift 6.2, `cc`, and `codesign`)
- **Runtime**: Node.js 22+
- **Host Client**: Google Antigravity (supporting plugins, MCP Apps side pane, and Skills)

---

## Features

- **Dual-Track & Mic-Only Recording**:
  - **Dual-track mode (`dual`)**: Captures global macOS system audio (remote participants) alongside your microphone (local speaker) for Zoom, Feishu/Lark, Tencent Meeting, browser calls, etc., writing mixed (`mix_*.m4a`), local mic (`mic_*.m4a`), and remote system (`remote_*.m4a`) audio plus speaker timelines (`timelines/chunk_*.json`).
  - **Mic-only mode (`mic`)**: Lightweight microphone capture for in-person discussions or voice notes.
- **Speaker Timelines & Distribution**: Uses per-track acoustic energy timelines to label **Me / Remote / Overlap** segments and displays per-speaker duration stats in meeting details.
- **Background Daemon & Graceful Finalization**: `MeetingRecorder.app` runs independently in the background without interrupting Antigravity conversation switching; supports 5-minute rolling chunks, audio device hot-swap detection, gap tracking (`gaps`), and safe chunk finalization before lid-close/sleep.
- **Resumable Independent-Session Transcription**: One-click trigger from the side pane opens a dedicated background session using the `meeting-notes` skill. Short meetings transcribe sequentially with per-chunk checkpoints; long meetings (> 4 chunks) fan out across parallel read-only subagents and stitch/save serially.
- **Full GFM Markdown Notes Viewer**: Built-in XSS-safe GitHub-Flavored Markdown renderer in the side pane supporting alerts/callouts, Action Items tables, fenced code blocks, nested/task lists, headings, and automatic light/dark theme adaptation.
- **Audio Retention & 100% Local Privacy**: Configurable raw-audio retention (`manual`, `after_notes`, `days_7`). All recordings, timelines, transcripts, and notes remain strictly local on your Mac—never uploaded to external recording clouds.

---

## Quick Start

> Run the following commands in a **macOS** terminal to build from source and install the plugin locally:

```bash
git clone https://github.com/nolinsun/anti-meeting.git
cd anti-meeting
npm install

# Optional (strongly recommended): create a local code-signing certificate
# ("Antigravity Meeting Local") so macOS TCC preserves permissions across rebuilds
bash recorder-macos/scripts/setup-local-cert.sh

# Build UI, native N-API addon, MCP server, and MeetingRecorder.app,
# then atomically install to ~/.gemini/config/plugins/anti-meeting
npm run install:plugin
```

After installation, open **anti-meeting** from the **"+"** menu in Google Antigravity's right side pane, or prompt the agent directly:

- `打开 anti-meeting 侧边栏并开始录制语音`
- `整理最近一场会议并生成结构化纪要和待办事项`
- `搜索历史会议中关于预算或接口方案的讨论`

---

## macOS Permissions

Before recording for the first time, grant permissions to `MeetingRecorder` under **System Settings → Privacy & Security**:

1. **Microphone**: Enable `MeetingRecorder` under **Privacy & Security → Microphone** (required for both modes).
2. **System Audio Recording Only** (required for `dual` mode): Enable `MeetingRecorder` under **Privacy & Security → Screen & System Audio Recording → System Audio Recording Only**.

> [!TIP]
> Use the **Audio Permissions & Devices** strip in the side pane (**Check Permissions**, **Privacy Settings**, or **Restart & Recheck**) to verify capture status. If permissions stop working after rebuilding or re-signing, toggle `MeetingRecorder` off and back on in System Settings, then click **Restart & Recheck** in the side pane.

---

## Project Structure

```text
anti-meeting/
├── recorder-macos/            # macOS Swift audio capture daemon (MeetingRecorder.app)
│   ├── Package.swift          # Swift 6.2 / macOS 26.0+ package manifest
│   ├── Sources/MeetingRecorder/
│   └── scripts/               # Local codesign cert setup & .app bundler scripts
├── mcp-server/                # MCP Server & macOS native safe file I/O addon
│   ├── native/                # safe_openat.c + swift_u64.swift (openat/flock/renamex_np)
│   └── src/                   # MCP tools, daemon client, checkpointing & retention store
├── ui/                        # MCP App side-pane frontend (bundled to plugin/ui/app.html)
│   ├── src/                   # app.ts, markdown.ts (GFM renderer), styles.css
│   └── scripts/               # build-ui.mjs & test-markdown.mjs
├── plugin/                    # Antigravity plugin manifest, skill & built bundle target
│   ├── plugin.json            # Plugin metadata
│   ├── mcp_config.json        # MCP server launch config
│   ├── assets/logo.svg        # Plugin icon
│   └── skills/meeting-notes/  # Transcription & structured notes workflow skill
├── scripts/
│   └── install-plugin.sh      # Full build & atomic install to ~/.gemini/config/plugins/anti-meeting
└── package.json
```

---

## Development & Verification

```bash
# TypeScript typecheck
npm run typecheck

# Run Markdown renderer unit & fixture tests
node ui/scripts/test-markdown.mjs

# Rebuild only the single-file UI bundle (plugin/ui/app.html)
npm run build:ui

# Full build (UI + native Node addon + MCP server + MeetingRecorder.app)
npm run build

# Validate plugin structure with the Antigravity CLI
agy plugin validate ./plugin
```

---

## Privacy & License

- **Local Storage Path**: Inside Antigravity, all audio chunks, speaker timelines, transcripts, and notes are stored locally under `~/.gemini/antigravity/plugin_data/anti-meeting/` (or `~/Library/Application Support/AntiMeeting/` when running the MCP server standalone without `--data-dir`).
- **License**: Released under the [MIT License](LICENSE).
