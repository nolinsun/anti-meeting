# Meeting Notes (`anti-meeting`)

[简体中文](README.md) | **English**

> A local **macOS** meeting recorder, dual-track speaker timeline generator, and structured Markdown meeting notes plugin (MCP App + Skill + Native Swift Recorder) for **Google Antigravity**.

> [!IMPORTANT]
> **macOS 14.2+ Required for Audio Recording**
> Dual-track system audio and microphone capture relies directly on **macOS Core Audio Process Tap**, **AVFoundation**, and **Swift** (`MeetingRecorder.app`). Windows and Linux can still run the MCP server safely to browse, search, and manage existing meeting notes and transcripts (showing a clear macOS-only banner for recording), while **audio capture requires macOS 14.2+ and Xcode Command Line Tools**.

---

## Requirements

- **Operating System (Recording)**: macOS 14.2 (Sonoma) or later
- **Build Toolchain**: Xcode Command Line Tools (`xcode-select --install`, including Swift, `cc`, and `codesign`)
- **Runtime**: Node.js 22+
- **Host Client**: Google Antigravity (supporting plugins, MCP Apps side pane / global view, and Skills)

---

## Key Features

- **Zero Unsigned Binaries in Plugin Bundles (Marketplace-Ready / Option B)**:
  - `npm run build:plugin` packages only the single-file UI (`plugin/ui/app.html`), executable MCP server (`plugin/scripts/meeting-mcp-server.mjs`), `meeting-notes` skill, and inspectable Swift/C sources (`plugin/sources/`). **No unsigned `.app` or `.node` binaries are distributed inside the plugin bundle.**
  - On first launch on macOS, clicking **Initialize Local Recorder** in the side pane compiles and locally signs `MeetingRecorder.app` (plus optional native helper `safe_openat.node`) directly into `${PLUGIN_DATA}/bin/`, keeping `${PLUGIN_ROOT}` read-only and avoiding cross-machine Gatekeeper quarantine issues.
  - Built-in pure-Node.js fallback keeps symlink-safe file operations working even without compiled native addons or on non-macOS hosts.
- **Bilingual UI Toggle & Quick Delete**:
  - Top-bar **EN / 中** language switcher (default **English**), persisted server-side in `settings.json`.
  - **Recent Recordings** on the **Record** tab includes a **Delete** button immediately after **View Details**, requiring an inline **Confirm Delete** click before deleting.
- **Dual-Track & Mic-Only Recording with Speaker Timelines**:
  - **Dual-track (`dual`)**: Captures global macOS system audio (remote participants) plus your microphone (local speaker) for Zoom, Google Meet, Microsoft Teams, Feishu/Lark, Tencent Meeting, and browser calls, producing mixed (`mix_*.m4a`), mic (`mic_*.m4a`), remote (`remote_*.m4a`) audio and speaker timelines (`timelines/chunk_*.json`).
  - **Mic-only (`mic`)**: Lightweight capture for in-person discussions or voice memos.
- **Independent Background Daemon & Resumable Transcription**:
  - `MeetingRecorder.app` runs independently in the background across Antigravity sessions with 5-minute rolling chunks, audio device change handling, gap tracking, and safe finalization before sleep/lid-close.
  - One-click **Generate Notes** launches a dedicated session using the `meeting-notes` skill (sequential per-chunk checkpointing for <= 4 chunks; parallel read-only subagent fan-out for > 4 chunks).
- **XSS-Safe GFM Markdown Viewer & Local Retention Policies**:
  - Renders alerts/callouts, Action Items tables, fenced code blocks, nested/task lists, and adapts automatically to light/dark themes.
  - Raw audio retention modes (`manual`, `after_notes`, `days_7`) never delete untranscribed audio automatically.

---

## Quick Start

> Run in a **macOS 14.2+** terminal to install locally (default plugin dir `~/.gemini/config/plugins/meeting-notes`, manifest `name: "meeting-notes"`, `displayName: "Meeting Notes"`):

```bash
git clone https://github.com/nolinsun/anti-meeting.git
cd anti-meeting
npm install

# Optional (recommended): create local codesign cert "Local Meeting Recorder"
# to help macOS TCC retain Microphone / System Audio permissions across rebuilds
bash recorder-macos/scripts/setup-local-cert.sh

# Option A (Dev full build): compile UI, MCP server, native addon, and MeetingRecorder.app,
# then install atomically to ~/.gemini/config/plugins/meeting-notes
npm run install:plugin

# Option B (Marketplace-style local setup): install without prebuilt binaries under plugin/bin/;
# compile MeetingRecorder.app on demand via "Initialize Local Recorder" in the side pane
bash scripts/install-plugin.sh --option-b
```

Open **Meeting Notes** from Google Antigravity's side pane **"+"** menu (or global view), or prompt the agent directly:

- `Open the Meeting Notes side pane and start recording a meeting`
- `Transcribe my most recent meeting and generate structured notes with action items`
- `Search past meeting notes and transcripts for budget or architecture decisions`

---

## macOS Permissions

Before recording for the first time, grant access to `MeetingRecorder` in **System Settings → Privacy & Security**:

1. **Microphone** (required for both Dual-Track and Mic-Only modes).
2. **Screen & System Audio Recording → System Audio Recording Only** (required for Dual-Track mode).

> [!TIP]
> Use the **Audio Permissions & Devices** strip in the side pane (**Check Permissions**, **Privacy Settings**, **Restart & Recheck**) to diagnose audio permissions at any time.

---

## Project Structure

```text
anti-meeting/
├── recorder-macos/            # macOS Swift audio capture daemon sources (macOS 14.2+)
│   ├── Package.swift          # Swift Package manifest (.macOS("14.2"))
│   ├── Sources/MeetingRecorder/
│   └── scripts/               # "Local Meeting Recorder" cert setup & .app bundler scripts
├── mcp-server/                # MCP Server & macOS safe file I/O (with pure-Node fallback)
│   ├── native/                # safe_openat.c + swift_u64.swift
│   ├── scripts/               # test-native-fallback.mjs tests
│   └── src/                   # config / native / runtimeSetup / daemon / store / index
├── ui/                        # MCP App frontend (bundled to plugin/ui/app.html)
│   ├── src/                   # app.ts, i18n.ts (EN/中), markdown.ts, styles.css
│   └── scripts/               # build-ui.mjs & test-markdown.mjs
├── plugin/                    # Antigravity plugin manifest, skill, executable server & bundled sources
│   ├── plugin.json            # name: "meeting-notes", displayName: "Meeting Notes", v0.4.0
│   ├── mcp_config.json        # Launches ${PLUGIN_ROOT}/scripts/meeting-mcp-server.mjs
│   ├── README.md              # Marketplace documentation
│   ├── assets/logo.svg        # Plugin icon
│   ├── skills/meeting-notes/  # Transcription & structured notes workflow skill
│   ├── scripts/               # (build output) meeting-mcp-server.mjs
│   ├── sources/               # (build output) synced recorder-macos/ & native/ sources
│   └── ui/app.html            # (build output) single-file UI bundle
├── scripts/
│   ├── sync-plugin-sources.mjs# Sync buildable Swift/C sources into plugin/sources/
│   └── install-plugin.sh      # Atomic install to ~/.gemini/config/plugins/meeting-notes (--dest / --option-b)
└── package.json
```

---

## Development & Verification

```bash
# TypeScript typecheck
npm run typecheck

# Run Markdown renderer & pure-Node safe file I/O tests
npm test

# Build binary-free Marketplace/Option-B plugin bundle (UI + scripts/ + sources/)
npm run build:plugin

# Full local build (including native safe_openat.node + MeetingRecorder.app)
npm run build

# Validate plugin structure with the Antigravity CLI
agy plugin validate ./plugin --strict
```

---

## Privacy & License

- **Local Data Directory**: Inside Antigravity, recordings, timelines, transcripts, and notes are stored locally under `${PLUGIN_DATA}` (e.g. `~/.gemini/antigravity/plugin_data/meeting-notes/` for fresh installs, `~/.gemini/antigravity/plugin_data/anti-meeting/` for in-place legacy upgrades via `--dest ~/.gemini/config/plugins/anti-meeting`, or `~/Library/Application Support/MeetingNotes/` when running standalone without `--data-dir`).
- **License**: Released under the [MIT License](LICENSE).
