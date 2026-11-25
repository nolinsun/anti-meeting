import fs from "node:fs";
import path from "node:path";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  registerAppResource,
  registerAppTool,
  RESOURCE_MIME_TYPE,
} from "@modelcontextprotocol/ext-apps/server";
import { z } from "zod";
import { loadConfig } from "./config.js";
import {
  DaemonRequestError,
  RecorderDaemonClient,
  type PermissionSnapshot,
  type RecorderStateSnapshot,
} from "./daemon.js";
import { configureNativeSearchDirs } from "./native.js";
import { buildLocalRuntime, getRuntimeStatus } from "./runtimeSetup.js";
import { MeetingStore } from "./store.js";

const APP_URI = "ui://meeting/app.html";
const MAX_ENVELOPE_BYTES = 950_000;
const COMPACT_TEXT_THRESHOLD_BYTES = 32_768;

function isWellFormedUnicode(text: string): boolean {
  const maybeFn = (text as unknown as { isWellFormed?: () => boolean }).isWellFormed;
  if (typeof maybeFn === "function") {
    return maybeFn.call(text);
  }
  return !/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?:^|[^\uD800-\uDBFF])[\uDC00-\uDFFF]/.test(text);
}

const wellFormedTitleSchema = z
  .string()
  .max(500)
  .refine((s) => isWellFormedUnicode(s), "会议标题包含非法未配对 Unicode 代理字符");

const wellFormedNonEmptyTitleSchema = z
  .string()
  .trim()
  .min(1)
  .max(500)
  .refine((s) => isWellFormedUnicode(s), "会议标题包含非法未配对 Unicode 代理字符");

function jsonResult(data: Record<string, unknown>, textSummary?: string) {
  let text = textSummary;
  if (text === undefined) {
    const compact = JSON.stringify(data);
    text =
      Buffer.byteLength(compact, "utf8") <= COMPACT_TEXT_THRESHOLD_BYTES
        ? JSON.stringify(data, null, 2)
        : compact;
  }
  const envelope = {
    content: [{ type: "text" as const, text }],
    structuredContent: data,
  };
  const totalBytes = Buffer.byteLength(JSON.stringify(envelope), "utf8");
  if (totalBytes > MAX_ENVELOPE_BYTES) {
    throw new Error(`工具返回载荷 (${totalBytes} B) 超过 1 MiB 安全上限，请改读磁盘文件路径`);
  }
  return envelope;
}

function errorResult(err: unknown) {
  const message =
    err instanceof DaemonRequestError
      ? `${err.message} (HTTP ${err.status})`
      : err instanceof Error
        ? err.message
        : String(err);
  return {
    isError: true,
    content: [{ type: "text" as const, text: message }],
  };
}

async function assertMeetingSafeToMutate(
  daemon: RecorderDaemonClient,
  store: MeetingStore,
  meetingId: string,
  action: "rename" | "cleanup" | "delete",
): Promise<void> {
  const probe = await daemon.probeStatus();
  if (probe.kind === "unknown") {
    throw new Error(`无法确认录音守护进程状态（${probe.error}），为安全起见已拒绝操作`);
  }
  if (probe.kind === "running" && probe.snapshot.meetingId === meetingId) {
    if (["starting", "recording", "finalizing"].includes(probe.snapshot.state)) {
      throw new Error(`会议 ${meetingId} 当前处于 ${probe.snapshot.state} 状态，禁止执行该操作`);
    }
  }

  const manifest = store.readManifest(meetingId);
  if (manifest.status === "recording" || manifest.status === "finalizing") {
    throw new Error(`磁盘清单显示会议处于 ${manifest.status} 状态，禁止在未结束录制时修改或删除`);
  }

  if (action !== "rename" && store.isTranscribing(meetingId)) {
    throw new Error(`会议 ${meetingId} 当前正在进行转写，禁止删除或清理原音频`);
  }
}

async function main() {
  const config = loadConfig();
  configureNativeSearchDirs([config.dataBinDir, path.join(config.pluginRoot, "bin")]);
  const store = new MeetingStore(config.meetingsDir, config.dataDir);
  try {
    store.ensureRoot();
  } catch {
    // Defer invalid/symlinked dataDir rejection to tool calls so MCP clients get clean isError responses without traversing symlinks.
  }
  const daemon = new RecorderDaemonClient(config);
  let lastRetentionSweepAt = 0;

  const server = new McpServer({
    name: "meeting-notes",
    version: "0.4.0",
  });

  registerAppResource(
    server,
    "Meeting Notes UI",
    APP_URI,
    {
      description: "Meeting Notes recorder side pane & history dashboard",
      _meta: {
        ui: {
          prefersBorder: false,
        },
      },
    },
    async () => {
      if (!fs.existsSync(config.uiHtmlPath)) {
        throw new Error(`UI bundle not found at ${config.uiHtmlPath}`);
      }
      const html = fs.readFileSync(config.uiHtmlPath, "utf8");
      if (!html.trim()) {
        throw new Error(`UI bundle at ${config.uiHtmlPath} is empty`);
      }
      return {
        contents: [
          {
            uri: APP_URI,
            mimeType: RESOURCE_MIME_TYPE,
            text: html,
            _meta: {
              ui: {
                prefersBorder: false,
              },
            },
          },
        ],
      };
    },
  );

  // Entrypoint tool for aux_pane & global views ("Meeting Notes").
  registerAppTool(
    server,
    "meeting_open_panel",
    {
      title: "Open Meeting Notes",
      description:
        "Open the Meeting Notes side pane or full-page view (live macOS recorder and meeting history). All arguments are optional.",
      annotations: {
        readOnlyHint: true,
        idempotentHint: true,
        openWorldHint: false,
      },
      inputSchema: {
        view: z.enum(["live", "history"]).optional(),
        meetingId: z.string().optional(),
      },
      _meta: {
        ui: {
          resourceUri: APP_URI,
        },
        "com.google.antigravity/ui": {
          entrypoints: [
            { type: "aux_pane", title: "Meeting Notes" },
            { type: "global", title: "Meeting Notes" },
          ],
        },
      },
    },
    async (args) => {
      try {
        store.ensureRoot();
        const runtimeStatus = await getRuntimeStatus(config);
        const settings = store.getSettings();
        const probe = await daemon.probeStatus();
        const list = store.listMeetings(30, 0);
        return jsonResult(
          {
            requestedView: args.view ?? null,
            requestedMeetingId: args.meetingId ?? null,
            runtimeStatus,
            settings,
            snapshot: probe.kind === "running" ? probe.snapshot : null,
            recentMeetings: list.items,
            totalMeetings: list.total,
          },
          `Meeting Notes panel ready (${list.total} meetings).`,
        );
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  // ---- Model + App shared tools ----

  server.registerTool(
    "meeting_start",
    {
      title: "Start Meeting Recording",
      description:
        "Start a local meeting recording session (macOS only): mode 'dual' (dual-track: global macOS system audio + microphone for Zoom, Feishu, Tencent Meeting, Google Meet, Teams, browsers, etc.) or 'mic' (mic-only).",
      annotations: {
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: false,
      },
      inputSchema: {
        mode: z
          .enum(["mic", "dual"])
          .optional()
          .describe("Recording mode: 'mic' (mic-only) or 'dual' (dual-track: global system audio + mic)"),
        title: wellFormedTitleSchema.optional().describe("Optional meeting title (max 500 characters)"),
        idempotencyKey: z.string().optional().describe("Optional idempotency key to prevent duplicate sessions"),
      },
    },
    async (args) => {
      try {
        store.ensureRoot();
        const mode = args.mode ?? "mic";
        const snapshot = await daemon.startSession({
          mode,
          appTarget: mode === "dual" ? "all_system" : "mic_only",
          title: args.title,
          idempotencyKey: args.idempotencyKey,
        });
        return jsonResult({ snapshot });
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "meeting_stop",
    {
      title: "Stop Meeting Recording",
      description:
        "Stop the active meeting recording, flush and atomically finalize the final audio chunk, and return the manifest.",
      annotations: {
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
      inputSchema: {
        meetingId: z.string().optional().describe("Optional meetingId guard so stop only stops the expected session"),
      },
    },
    async (args) => {
      try {
        store.ensureRoot();
        const stopped = await daemon.stopSession(args.meetingId);
        const fullPayload = {
          snapshot: stopped.snapshot,
          manifest: stopped.manifest ?? null,
        };
        try {
          return jsonResult(fullPayload);
        } catch {
          const slimManifest = stopped.manifest ? store.toViewManifest(stopped.manifest) : null;
          return jsonResult(
            {
              snapshot: { ...stopped.snapshot, chunks: [] },
              manifest: slimManifest,
              chunksOmitted: true,
              chunkCount: stopped.manifest?.chunks.length ?? stopped.snapshot.committedChunkCount,
            },
            `Stopped meeting ${stopped.manifest?.id ?? stopped.snapshot.meetingId ?? ""}; call meeting_get to paginate chunks.`,
          );
        }
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "meeting_status",
    {
      title: "Get Recording Status",
      description: "Query live recorder state, elapsed duration, audio levels, and committed chunks.",
      annotations: {
        readOnlyHint: true,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    async () => {
      try {
        store.ensureRoot();
        const snapshot = await daemon.getStatus();
        const permissions = await daemon.getPermissions();
        return jsonResult({ snapshot, permissions });
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "meeting_get",
    {
      title: "Get Meeting Chunks & Progress",
      description:
        "Get meeting manifest, absolute audio chunk paths (absoluteAudioPath plus dual-track absoluteMicPath, absoluteRemotePath, and speaker timeline absoluteTimelinePath) for read_file, completed/missing chunk IDs, pagination fields (totalChunks, hasMoreChunks, nextChunkOffset), and transcript/notes file paths.",
      annotations: {
        readOnlyHint: true,
        idempotentHint: true,
        openWorldHint: false,
      },
      inputSchema: {
        meetingId: z.string().describe("Target meeting ID"),
        chunkOffset: z.number().int().min(0).optional().describe("Zero-based pagination offset into chunks"),
        chunkLimit: z.number().int().min(1).max(500).optional().describe("Maximum chunks to return per page"),
        onlyMissing: z.boolean().optional().describe("When true, paginate only over chunks not yet transcribed"),
      },
    },
    async (args) => {
      try {
        let prebuiltResult: ReturnType<typeof jsonResult> | null = null;
        const detail = store.getMeetingForModel(args.meetingId, {
          chunkOffset: args.chunkOffset,
          chunkLimit: args.chunkLimit,
          onlyMissing: args.onlyMissing,
          acquireLeaseIfNeeded: true,
          beforeLease: (payload) => {
            prebuiltResult = jsonResult({ ...payload });
          },
        });
        try {
          store.touchNotesJob(args.meetingId);
        } catch {
          // Best-effort job heartbeat update must never fail meeting_get.
        }
        return prebuiltResult ?? jsonResult({ ...detail });
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "meeting_list",
    {
      title: "List Meetings",
      description: "List recorded meetings ordered newest-first with transcription and notes status.",
      annotations: {
        readOnlyHint: true,
        idempotentHint: true,
        openWorldHint: false,
      },
      inputSchema: {
        limit: z.number().int().min(1).max(200).optional(),
        offset: z.number().int().min(0).optional(),
      },
    },
    async (args) => {
      try {
        const result = store.listMeetings(args.limit ?? 30, args.offset ?? 0);
        return jsonResult(result);
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "meeting_search",
    {
      title: "Search Meetings",
      description: "Search across meeting titles, notes, and transcripts by keyword.",
      annotations: {
        readOnlyHint: true,
        idempotentHint: true,
        openWorldHint: false,
      },
      inputSchema: {
        query: z.string().min(1).describe("Search keyword"),
        limit: z.number().int().min(1).max(50).optional(),
      },
    },
    async (args) => {
      try {
        const hits = store.searchMeetings(args.query, args.limit ?? 20);
        return jsonResult({ query: args.query, hits });
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "meeting_save_result",
    {
      title: "Save Transcript & Notes",
      description:
        "Persist per-chunk transcript (kind='chunk_transcript' with chunkId), stitched full transcript (kind='full_transcript'), meeting notes (kind='notes'), or multiple artifacts in one call (kind='bundle' with chunkTranscript/fullTranscript/notes).",
      annotations: {
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
      inputSchema: {
        meetingId: z.string().describe("Target meeting ID"),
        kind: z.enum(["chunk_transcript", "full_transcript", "notes", "bundle"]),
        chunkId: z
          .string()
          .max(64)
          .optional()
          .describe("Required when kind='chunk_transcript' or when kind='bundle' includes chunkTranscript, e.g. 'chunk_001'"),
        content: z
          .string()
          .optional()
          .describe("Markdown content for kind='chunk_transcript', 'full_transcript', or 'notes'"),
        chunkTranscript: z
          .string()
          .optional()
          .describe("Optional per-chunk transcript Markdown when kind='bundle' (requires chunkId)"),
        fullTranscript: z
          .string()
          .optional()
          .describe("Optional stitched full transcript Markdown when kind='bundle'"),
        notes: z
          .string()
          .optional()
          .describe("Optional structured meeting notes Markdown when kind='bundle'"),
        title: wellFormedTitleSchema.optional().describe("Optional updated meeting title"),
      },
    },
    async (args) => {
      try {
        const runAfterNotesAutoCleanup = async (shouldCleanup: boolean) => {
          let autoCleanup: { cleaned: boolean; freedBytes: number } = { cleaned: false, freedBytes: 0 };
          if (shouldCleanup && store.getSettings().audioRetentionPolicy === "after_notes") {
            try {
              const probe = await daemon.probeStatus();
              const activeBusyId =
                probe.kind === "running" &&
                ["starting", "recording", "finalizing"].includes(probe.snapshot.state)
                  ? probe.snapshot.meetingId
                  : null;
              if (probe.kind !== "unknown" && activeBusyId !== args.meetingId) {
                autoCleanup = store.tryAutoCleanupAfterNotes(args.meetingId);
              }
            } catch {
              // Auto cleanup is best-effort and must never fail an already saved notes result.
            }
          }
          return autoCleanup;
        };

        if (args.kind !== "bundle") {
          if (typeof args.content !== "string") {
            throw new Error(`kind='${args.kind}' requires 'content'`);
          }
          let prebuiltResult: ReturnType<typeof jsonResult> | null = null;
          const saved = store.saveResult({
            meetingId: args.meetingId,
            kind: args.kind,
            chunkId: args.chunkId,
            content: args.content,
            title: args.title,
            manageLease: true,
            beforeCommit: (preview) => {
              prebuiltResult = jsonResult({ ...preview });
            },
          });
          try {
            if (args.kind === "notes") {
              store.releaseNotesJob(args.meetingId);
            } else {
              store.touchNotesJob(args.meetingId);
            }
          } catch {
            // Best-effort job tracking update must never fail an already saved result.
          }
          const autoCleanup = await runAfterNotesAutoCleanup(args.kind === "notes");
          if (autoCleanup.cleaned) {
            return jsonResult({
              savedPath: saved.savedPath,
              meetingId: saved.meetingId,
              kind: saved.kind,
              ...(saved.chunkId !== undefined ? { chunkId: saved.chunkId } : {}),
              autoCleanedAudio: true,
              autoCleanedBytes: autoCleanup.freedBytes,
            });
          }
          return (
            prebuiltResult ??
            jsonResult({
              savedPath: saved.savedPath,
              meetingId: saved.meetingId,
              kind: saved.kind,
              ...(saved.chunkId !== undefined ? { chunkId: saved.chunkId } : {}),
            })
          );
        }

        const ops: Array<{
          kind: "chunk_transcript" | "full_transcript" | "notes";
          chunkId?: string;
          content: string;
        }> = [];
        if (typeof args.chunkTranscript === "string") {
          if (!args.chunkId || !args.chunkId.trim()) {
            throw new Error("kind='bundle' with chunkTranscript requires chunkId");
          }
          ops.push({
            kind: "chunk_transcript",
            chunkId: args.chunkId,
            content: args.chunkTranscript,
          });
        }
        if (typeof args.fullTranscript === "string") {
          ops.push({ kind: "full_transcript", content: args.fullTranscript });
        }
        if (typeof args.notes === "string") {
          ops.push({ kind: "notes", content: args.notes });
        }
        if (ops.length === 0) {
          throw new Error(
            "kind='bundle' requires at least one of chunkTranscript, fullTranscript, or notes",
          );
        }

        const savedPaths: {
          chunkTranscriptPath?: string;
          transcriptPath?: string;
          notesPath?: string;
        } = {};
        let lastSavedPath = "";
        let savedChunkId: string | undefined;
        let savedNotes = false;

        for (let i = 0; i < ops.length; i += 1) {
          const op = ops[i];
          const isLast = i === ops.length - 1;
          const saved = store.saveResult({
            meetingId: args.meetingId,
            kind: op.kind,
            chunkId: op.chunkId,
            content: op.content,
            title: isLast ? args.title : undefined,
            manageLease: true,
          });
          lastSavedPath = saved.savedPath;
          if (op.kind === "chunk_transcript") {
            savedPaths.chunkTranscriptPath = saved.savedPath;
            savedChunkId = saved.chunkId;
          } else if (op.kind === "full_transcript") {
            savedPaths.transcriptPath = saved.savedPath;
          } else {
            savedPaths.notesPath = saved.savedPath;
            savedNotes = true;
          }
        }

        try {
          if (savedNotes) {
            store.releaseNotesJob(args.meetingId);
          } else {
            store.touchNotesJob(args.meetingId);
          }
        } catch {
          // Best-effort job tracking update must never fail an already saved result.
        }

        const autoCleanup = await runAfterNotesAutoCleanup(savedNotes);
        return jsonResult({
          meetingId: args.meetingId,
          kind: "bundle",
          savedPath: lastSavedPath,
          savedPaths,
          ...(savedChunkId !== undefined ? { chunkId: savedChunkId } : {}),
          ...(autoCleanup.cleaned
            ? { autoCleanedAudio: true, autoCleanedBytes: autoCleanup.freedBytes }
            : {}),
        });
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  // ---- App-only UI helper tools (hidden from model) ----

  server.registerTool(
    "app_poll_live",
    {
      title: "轮询实时录制状态",
      description: "UI-only live state polling for recorder status, permissions, and recent meetings.",
      inputSchema: {
        autoLaunch: z.boolean().optional().describe("Only true when user explicitly opens/retries live recorder"),
        selectedMeetingId: z
          .string()
          .optional()
          .describe("Optional currently selected meeting ID in history view to track live updates beyond top 30 and body edits"),
        trackedMeetingIds: z
          .array(z.string())
          .max(50)
          .optional()
          .describe("Optional meeting IDs with in-flight notes generation jobs to track summaries beyond top 30"),
      },
      _meta: {
        ui: { visibility: ["app"] },
      },
    },
    async (args) => {
      try {
        store.ensureRoot();
        const runtimeStatus = await getRuntimeStatus(config);
        let daemonRunning = false;
        let daemonError: string | null = null;
        let snapshot: RecorderStateSnapshot | null = null;
        let permissions: PermissionSnapshot = { mic: "not_determined", systemAudio: "unverified" };

        if (args.autoLaunch === true && runtimeStatus.supported && runtimeStatus.appReady) {
          try {
            snapshot = await daemon.getStatus();
            permissions = await daemon.getPermissions();
            daemonRunning = true;
          } catch (err) {
            daemonError = err instanceof Error ? err.message : String(err);
          }
        } else if (runtimeStatus.supported) {
          const probe = await daemon.probeStatus();
          if (probe.kind === "running") {
            daemonRunning = true;
            snapshot = probe.snapshot;
            const perms = await daemon.tryGetPermissionsIfRunning();
            if (perms) permissions = perms;
          } else if (probe.kind === "unknown") {
            daemonError = probe.error;
          }
        }

        const settings = store.getSettings();
        if (
          settings.audioRetentionPolicy === "days_7" &&
          daemonError === null &&
          Date.now() - lastRetentionSweepAt >= 10 * 60_000
        ) {
          const skipMeetingId =
            snapshot && ["starting", "recording", "finalizing"].includes(snapshot.state)
              ? snapshot.meetingId ?? null
              : null;
          try {
            store.applyRetentionPolicy({ skipMeetingId });
            lastRetentionSweepAt = Date.now();
          } catch {
            // Keep polling responsive even if a sweep encounter transient errors.
          }
        }

        const list = store.listMeetings(30, 0);
        const selectedMeeting =
          typeof args.selectedMeetingId === "string" && args.selectedMeetingId.trim().length > 0
            ? (() => {
                try {
                  return store.getMeetingRevision(args.selectedMeetingId.trim());
                } catch {
                  return null;
                }
              })()
            : null;
        const activeNotesJobIds = store.listActiveNotesJobIds();
        const trackedIds = Array.isArray(args.trackedMeetingIds)
          ? [...args.trackedMeetingIds, ...activeNotesJobIds]
          : activeNotesJobIds;
        const trackedSummaries =
          trackedIds.length > 0 ? store.getSummariesByIds(trackedIds) : {};
        return jsonResult(
          {
            runtimeStatus,
            daemonRunning,
            daemonError,
            snapshot,
            permissions,
            settings,
            recentMeetings: list.items,
            totalMeetings: list.total,
            selectedMeeting,
            activeNotesJobIds,
            trackedSummaries,
          },
          `daemonRunning=${daemonRunning}, appReady=${runtimeStatus.appReady}, meetings=${list.total}`,
        );
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "app_request_permission",
    {
      title: "请求录音权限",
      description: "UI-only helper to request microphone permission or open macOS Privacy settings.",
      inputSchema: {
        kind: z.enum(["mic", "systemAudio"]).optional(),
        openSettings: z.boolean().optional(),
        restartDaemon: z.boolean().optional(),
      },
      _meta: {
        ui: { visibility: ["app"] },
      },
    },
    async (args) => {
      try {
        store.ensureRoot();
        if (args.restartDaemon === true) {
          const restarted = await daemon.restartIfIdle();
          return jsonResult(
            {
              prompting: false,
              restarted: restarted.restarted,
              permissions: restarted.permissions,
              snapshot: restarted.snapshot,
            },
            `restarted=${restarted.restarted}, mic=${restarted.permissions.mic}, systemAudio=${restarted.permissions.systemAudio}`,
          );
        }
        const res = await daemon.requestPermission(
          args.kind ?? "mic",
          args.openSettings ?? false,
        );
        return jsonResult(
          { ...res },
          `mic=${res.permissions.mic}, systemAudio=${res.permissions.systemAudio}, prompting=${res.prompting}`,
        );
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "app_get_meeting",
    {
      title: "UI读取会议详情",
      description: "UI-only helper returning meeting notes, transcript, and audio cleanup metadata.",
      inputSchema: {
        meetingId: z.string(),
      },
      _meta: {
        ui: { visibility: ["app"] },
      },
    },
    async ({ meetingId }) => {
      try {
        const detail = store.getMeetingView(meetingId);
        return jsonResult(
          { ...detail },
          `Loaded meeting ${meetingId} (notes=${detail.notes.length} chars, transcript=${detail.transcript.length} chars)`,
        );
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "app_rename_meeting",
    {
      title: "UI重命名会议",
      description: "UI-only helper to update a meeting title.",
      inputSchema: {
        meetingId: z.string(),
        title: wellFormedNonEmptyTitleSchema,
      },
      _meta: {
        ui: { visibility: ["app"] },
      },
    },
    async ({ meetingId, title }) => {
      try {
        await assertMeetingSafeToMutate(daemon, store, meetingId, "rename");
        let prebuiltResult: ReturnType<typeof jsonResult> | null = null;
        const manifest = store.renameMeeting(meetingId, title, (preview) => {
          prebuiltResult = jsonResult({ manifest: preview }, `Renamed ${meetingId}`);
        });
        return (
          prebuiltResult ??
          jsonResult({ manifest: store.toViewManifest(manifest) }, `Renamed ${meetingId}`)
        );
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "app_cleanup_audio",
    {
      title: "UI清理原始音频",
      description: "UI-only helper to delete raw .m4a chunks while keeping notes and transcripts.",
      inputSchema: {
        meetingId: z.string(),
      },
      _meta: {
        ui: { visibility: ["app"] },
      },
    },
    async ({ meetingId }) => {
      try {
        await assertMeetingSafeToMutate(daemon, store, meetingId, "cleanup");
        const res = store.cleanupAudio(meetingId);
        return jsonResult(res, `Cleaned audio for ${meetingId} (${res.freedBytes} bytes)`);
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "app_delete_meeting",
    {
      title: "UI删除会议记录",
      description: "UI-only helper to delete an entire meeting folder.",
      inputSchema: {
        meetingId: z.string(),
      },
      _meta: {
        ui: { visibility: ["app"] },
      },
    },
    async ({ meetingId }) => {
      try {
        await assertMeetingSafeToMutate(daemon, store, meetingId, "delete");
        const res = store.deleteMeeting(meetingId);
        try {
          store.releaseNotesJob(meetingId);
        } catch {
          // ignore
        }
        return jsonResult(res, `Deleted meeting ${meetingId}`);
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "app_set_settings",
    {
      title: "Update Plugin Settings",
      description:
        "UI-only helper to configure audio retention policy or UI language and optionally sweep completed meetings.",
      inputSchema: {
        audioRetentionPolicy: z.enum(["manual", "after_notes", "days_7"]).optional(),
        uiLanguage: z.enum(["en", "zh"]).optional(),
        applyNow: z.boolean().optional(),
      },
      _meta: {
        ui: { visibility: ["app"] },
      },
    },
    async (args) => {
      try {
        const settings = store.setSettings({
          ...(args.audioRetentionPolicy !== undefined
            ? { audioRetentionPolicy: args.audioRetentionPolicy }
            : {}),
          ...(args.uiLanguage !== undefined ? { uiLanguage: args.uiLanguage } : {}),
        });
        let sweep: { cleanedMeetingIds: string[]; freedBytes: number } = {
          cleanedMeetingIds: [],
          freedBytes: 0,
        };
        if (
          (args.audioRetentionPolicy !== undefined || args.applyNow === true) &&
          (settings.audioRetentionPolicy === "days_7" ||
            (settings.audioRetentionPolicy === "after_notes" && args.applyNow === true))
        ) {
          const probe = await daemon.probeStatus();
          if (probe.kind !== "unknown") {
            const skipMeetingId =
              probe.kind === "running" &&
              ["starting", "recording", "finalizing"].includes(probe.snapshot.state)
                ? probe.snapshot.meetingId ?? null
                : null;
            sweep = store.applyRetentionPolicy({
              skipMeetingId,
              includeAfterNotes: args.applyNow === true,
            });
            lastRetentionSweepAt = Date.now();
          }
        }
        return jsonResult(
          {
            settings,
            cleanedCount: sweep.cleanedMeetingIds.length,
            cleanedMeetingIds: sweep.cleanedMeetingIds,
            freedBytes: sweep.freedBytes,
          },
          `policy=${settings.audioRetentionPolicy}, lang=${settings.uiLanguage}, cleaned=${sweep.cleanedMeetingIds.length}`,
        );
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "app_setup_runtime",
    {
      title: "Initialize Local Recorder",
      description: "UI-only helper to compile and sign MeetingRecorder.app locally on macOS.",
      inputSchema: {},
      _meta: {
        ui: { visibility: ["app"] },
      },
    },
    async () => {
      try {
        const runtimeStatus = await buildLocalRuntime(config);
        let daemonRunning = false;
        let daemonError: string | null = null;
        let snapshot: RecorderStateSnapshot | null = null;
        let permissions: PermissionSnapshot = { mic: "not_determined", systemAudio: "unverified" };
        try {
          snapshot = await daemon.getStatus();
          permissions = await daemon.getPermissions();
          daemonRunning = true;
        } catch (err) {
          daemonError = err instanceof Error ? err.message : String(err);
        }
        return jsonResult(
          {
            runtimeStatus,
            daemonRunning,
            daemonError,
            snapshot,
            permissions,
          },
          `Local recorder ready (nativeAddon=${runtimeStatus.nativeAddonLoaded}, daemonRunning=${daemonRunning}).`,
        );
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  server.registerTool(
    "app_notes_job",
    {
      title: "纪要生成任务状态管理",
      description: "UI-only helper to claim or release a single-flight notes generation job across panel views.",
      inputSchema: {
        action: z.enum(["claim", "release"]),
        meetingId: z.string(),
        clientJobId: z.string().min(1).max(128).optional(),
      },
      _meta: {
        ui: { visibility: ["app"] },
      },
    },
    async ({ action, meetingId, clientJobId }) => {
      try {
        store.ensureRoot();
        if (action === "claim") {
          const res = store.claimNotesJob(meetingId, clientJobId);
          return jsonResult(res, `claimed=${res.claimed}, meetingId=${meetingId}`);
        }
        const released = store.releaseNotesJob(meetingId, clientJobId);
        return jsonResult({ released, meetingId }, `released=${released}, meetingId=${meetingId}`);
      } catch (err) {
        return errorResult(err);
      }
    },
  );

  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((err) => {
  console.error("[meeting-notes] fatal error:", err);
  process.exit(1);
});
