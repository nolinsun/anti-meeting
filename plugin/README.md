# Meeting Notes

> [!IMPORTANT]
> **macOS 14.2+ Required for Audio Recording**
> Dual-track system audio + microphone recording uses **macOS Core Audio Process Tap** & **AVFoundation** (`MeetingRecorder.app`). Windows and Linux can still browse, search, and manage existing meeting notes and transcripts, while local recording requires macOS 14.2+ and Xcode Command Line Tools (`xcode-select --install`).

## Overview

**Meeting Notes** is a local meeting recorder, dual-track speaker timeline generator, and structured Markdown notes plugin for **Google Antigravity**:

- **Dual-Track & Mic-Only Capture**: Record global macOS system audio alongside your microphone (compatible with Zoom, Google Meet, Microsoft Teams, Feishu/Lark, Tencent Meeting, and browser calls), or record microphone-only voice notes.
- **No Prebuilt Unsigned Binaries (Local Setup)**: To keep the plugin clean and avoid Apple Gatekeeper quarantine prompts, no precompiled `.app` or `.node` binaries are bundled. Click **Initialize Local Recorder** in the side pane on first use (about 20–40 seconds) to compile `MeetingRecorder.app` locally into your plugin data directory (`${PLUGIN_DATA}/bin/`).
- **Bilingual UI (EN / 中文)**: Switch between **English** (default) and **Chinese** anytime from the top bar; preference is saved locally per workspace profile.
- **Background Daemon & Resumable Transcription**: Recording continues reliably in the background across Antigravity conversation switches and handles device changes or lid-close finalization. Trigger `meeting-notes` from the side pane to transcribe chunks with checkpoints and render full GFM Markdown notes.

## Privacy & Data Flow

- **100% Local Storage**: Audio chunks (`.m4a`), speaker timelines (`timelines/*.json`), transcripts, and Markdown notes live strictly on your machine under `${PLUGIN_DATA}/meetings/` (nothing is uploaded to any third-party recording cloud).
- **On-Demand Model Access**: Audio chunks are only read by the agent when you explicitly click **Generate Notes** or invoke the `meeting-notes` skill / MCP tools.
- **Configurable Retention**: Keep raw `.m4a` files manually, auto-clean them after notes finish, or expire raw audio after 7 days while preserving notes and transcripts.

## macOS Permissions

Before your first recording, grant `MeetingRecorder` access under **System Settings → Privacy & Security**:

1. **Microphone** (required for all recording modes).
2. **Screen & System Audio Recording → System Audio Recording Only** (required for Dual-Track mode).

## Starter Prompts

- `Open the Meeting Notes side pane and start recording a meeting`
- `Transcribe my most recent meeting and generate structured notes with action items`
- `Search past meeting notes and transcripts for budget or architecture decisions`
