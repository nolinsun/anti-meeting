---
name: meeting-notes
description: Transcribe locally recorded anti-meeting audio chunks (sequentially for <= 4 chunks, or grouped 2-3 chunks via parallel read-only research subagents for > 4 missing chunks) via read_file supporting dual-track (`dual`) with speaker timelines and mic-only (`mic`), correct terms using workspace context, and persist structured meeting notes. Activate when the user asks to transcribe, summarize, or generate notes for a recorded meeting.
---

# Meeting Transcription & Notes Workflow

Follow this sequential, resumable workflow whenever asked to transcribe or summarize a meeting recorded by **anti-meeting**:

## 1. Inspect Meeting & Resume State

1. If the user did not supply a `meetingId`, call `meeting_list({ limit: 10 })` to find the most recent meeting (or ask if ambiguous).
2. Call `meeting_get({ meetingId })` to inspect:
   - `manifest` (`title`, `mode` (`"dual"` or `"mic"`), `appTarget`, `status`, `totalDurationSec`, `gaps`, `failedChunkCount`, `audioCleaned`)
   - `chunks` (ordered page with `id`, `absoluteAudioPath`, `fileExists`, `absoluteMicPath`, `micFileExists`, `absoluteRemotePath`, `remoteFileExists`, `absoluteTimelinePath`, `timelineFileExists`, `audioRangeSec`, `responsibleRangeSec`, `transcribed`)
   - Pagination fields: `totalChunks`, `chunkOffset`, `hasMoreChunks`, `nextChunkOffset`. Both `chunkOffset` and `nextChunkOffset` are stable 0-based indices into `manifest.chunks` (never relative to the shrinking missing list). When `hasMoreChunks === true`, call `meeting_get({ meetingId, chunkOffset: nextChunkOffset })` (optionally with `onlyMissing: true`) until `hasMoreChunks === false` so no chunk is skipped on long or resumed meetings.
   - `transcribedChunkIds`, `missingChunkIds`, `partialTranscriptPaths`, `transcriptPath`, `notesPath`
3. Stop early with a clear explanation if:
   - `manifest.status === "recording"` or `manifest.status === "finalizing"` (do **not** finalize full transcript or notes while recording is still active or finalizing; wait for stop first).
   - `manifest.status === "empty"` or `totalChunks === 0` (nothing recorded).
   - Every chunk across all pages has no readable audio (`fileExists === false` and in dual mode also `micFileExists !== true && remoteFileExists !== true`) and `transcribedChunkIds.length === 0`.

## 2. Transcribe Readable Missing Chunks (Sequential <= 4 / Parallel Subagents > 4)

Process **only** chunks listed in `missingChunkIds` in ascending `index` order (skip chunks already in `transcribedChunkIds` unless the user explicitly requested a full re-transcription).

### 2A. Routing Strategy
- **Short meeting / resume (`missingChunkIds.length <= 4`)**: The coordinator Agent processes each missing chunk sequentially with `read_file` and persists each chunk immediately via `meeting_save_result`.
- **Long meeting (`missingChunkIds.length > 4`)**:
  1. First finish paginating `meeting_get` (`chunkOffset: nextChunkOffset` until `hasMoreChunks === false`) so you have the full list of missing chunks, their paths, time ranges, and dual-track (`dual`) timeline/track existence flags.
  2. Partition readable missing chunks in ascending `index` order into groups of **2–3 consecutive chunks** each.
  3. Launch **2–4 read-only subagents concurrently** via `invoke_subagent({ TypeName: "research", ... })` (one per chunk group). Instruct each subagent to:
     - Read ONLY its assigned chunks (`absoluteAudioPath`, plus `absoluteTimelinePath` and surviving `absoluteMicPath`/`absoluteRemotePath` when needed per Section 2B below);
     - Follow every rule in Section 2B (including `[responsibleRangeSec[0], responsibleRangeSec[1])` attribution and global `[MM:SS]` timestamps);
     - Return clean per-chunk Markdown transcripts labeled clearly by `chunk.id` (do **not** modify files or call write tools from read-only subagents).
  4. As subagents complete, the coordinator persists each chunk **serially** via `meeting_save_result({ meetingId, kind: "chunk_transcript", chunkId: chunk.id, content })` in ascending `index` order so partial progress is safely checkpointed without concurrent write races.
  5. If subagent execution is unavailable or quota-limited, fall back cleanly to sequential chunk transcription.

### 2B. Per-Chunk Audio & Timeline Rules

For each chunk:
1. Check readable audio:
   - If `chunk.fileExists === true`: read `chunk.absoluteAudioPath` via `read_file` (applies to both `mic` and `dual`).
   - Else (`chunk.fileExists === false`):
     - If `manifest.mode === "dual"` and (`chunk.micFileExists === true` or `chunk.remoteFileExists === true`): read only the surviving track(s) (`absoluteMicPath` / `absoluteRemotePath`) via `read_file` and explicitly note which track was missing.
     - Otherwise (mic-only (`mic`) with `chunk.fileExists === false`, or dual-track (`dual`) with no surviving tracks): do **not** call `read_file` on missing paths and do **not** abort the entire meeting if other chunks exist; record this chunk ID as `audio_missing` so it is reported in the `> [!WARNING] 部分完成` callout later, and continue to the next chunk.
2. **Dual-track (`dual`) speaker timeline grounding**:
   - When `manifest.mode === "dual"` and `chunk.timelineFileExists === true && chunk.absoluteTimelinePath`, read `chunk.absoluteTimelinePath` (`timelines/chunk_NNN.json`) via `read_file` BEFORE/WITH transcribing.
   - Use its `segments` (`startSec`, `endSec`, `speaker`: `"me"` | `"remote"` | `"both"`) as primary acoustic evidence to label dialogue lines consistently as **`我方`** vs **`对方`** (or participant names when identified from speech).
   - For `"both"` overlap intervals or unclear crosstalk where the mix is ambiguous, read `chunk.absoluteMicPath` **only if** `chunk.micFileExists === true && chunk.absoluteMicPath`, and/or `chunk.absoluteRemotePath` **only if** `chunk.remoteFileExists === true && chunk.absoluteRemotePath`, via `read_file` to disambiguate cleanly.
3. Listen to the entire chunk from start to finish:
   - Each chunk begins at `[00:00]` local audio time, corresponding to `audioRangeSec[0]` in global meeting time.
   - For chunk 2+, the initial overlap window (`[audioRangeSec[0], responsibleRangeSec[0])`) repeats the tail of the previous chunk. Use that overlap **only** as context so split words aren't dropped; **attribute each utterance strictly using the half-open responsible interval `[responsibleRangeSec[0], responsibleRangeSec[1])`** so cross-boundary sentences/phrases are kept exactly once.
   - Convert timestamps to global meeting `[MM:SS]` format (`audioRangeSec[0] + localSec`).
4. Verify critical details carefully against the audio:
   - Exact **numbers, budgets, dates, percentages, and latency metrics**
   - **Negations** (`不是...而是...`, `不要...`, `不能...`)
   - **Action-item owners and deadlines**
5. Immediately persist the chunk transcript via:
   `meeting_save_result({ meetingId, kind: "chunk_transcript", chunkId: chunk.id, content })`
   Persisting after each chunk guarantees completed chunks are never lost if interrupted or quota-limited.

## 3. Workspace Context Correction & Stitching

1. Re-fetch `meeting_get({ meetingId })` (and paginate with `chunkOffset: nextChunkOffset` if `hasMoreChunks === true`) before finalizing to ensure `manifest` state, full `partialTranscriptPaths`, and chunk list are current.
2. Read any previously completed chunk transcripts in `partialTranscriptPaths` via `read_file`.
3. When parallel subagent batches were used, **normalize speaker names/labels across all chunk groups** (e.g., unify inconsistent `参会者 A/B` labels referring to the same person) and verify no duplicated sentences remain across chunk boundaries.
4. If an active workspace is open, check key files/docs/symbol names when ambiguous homophones appear (e.g., project names, API endpoints, module names, team member names) and normalize technical terminology consistently across all chunks.
5. Merge all available chunk transcripts in order into a clean, deduplicated Markdown transcript with `[MM:SS]` timestamps (and `我方` / `对方` labels for dual-track meetings), clearly inserting `[缺口说明：...]` markers where any `gaps` (`mic_*`, `system_audio_*`, `device_switched`, etc.) or missing/failed chunks occurred. Never fabricate dialogue during an uncaptured gap.
6. Persist the stitched transcript via:
   `meeting_save_result({ meetingId, kind: "full_transcript", content })`

## 4. Generate & Persist Structured Notes

Produce concise, accurate Markdown meeting notes containing:
- If `manifest.status === "partial"`, `(manifest.failedChunkCount ?? 0) > 0`, `(manifest.gaps?.length ?? 0) > 0`, or any chunk had missing audio, place a prominent **`> [!WARNING] 部分完成`** callout at the top listing every gap window, failed chunk, or missing track/chunk.
- **一句话概要**
- **议题与关键结论**（只记录音频中真实讨论过的内容，不脑补未提及细节）
- **行动项（Action Items）**（表格或列表：`事项 | 负责人 | 截止时间`）
- **风险、分歧与待确认项**

Save the notes via:
`meeting_save_result({ meetingId, kind: "notes", content, title })`
(Pass an improved concise `title` if the current title is still an auto-generated `语音记录 MM-DD HH:mm` or `双轨会议 MM-DD HH:mm`.)

## 5. Present Result to User

Reply concisely with the structured meeting notes and clickable `file://` links to the saved `notesPath` and `transcriptPath`.
