import {
  App,
  applyDocumentTheme,
  applyHostStyleVariables,
} from "@modelcontextprotocol/ext-apps";
import { escapeHtml, renderMarkdown } from "./markdown";

interface ChunkRecord {
  index: number;
  id: string;
  audioPath: string;
  micPath?: string;
  remotePath?: string;
  timelinePath?: string;
  audioRangeSec: [number, number];
  responsibleRangeSec: [number, number];
  durationSec: number;
  byteSize: number;
}

interface RecorderSnapshot {
  state: "idle" | "starting" | "recording" | "finalizing" | "error" | string;
  meetingId?: string;
  title?: string;
  mode?: string;
  elapsedSec: number;
  meLevel: number;
  remoteLevel: number;
  committedChunkCount: number;
  chunks: ChunkRecord[];
  gaps?: Array<{ startSec: number; endSec: number; reason: string }>;
  failedChunkCount?: number;
  inputDeviceName?: string;
  outputDeviceName?: string;
  systemAudioStatus?: string;
  lastError?: string;
}

interface PermissionSnapshot {
  mic: string;
  systemAudio: string;
  otherAudioPlaying?: boolean;
  tapReady?: boolean;
}

interface MeetingSummary {
  id: string;
  title: string;
  mode: string;
  appTarget?: string;
  status: string;
  createdAt: string;
  endedAt?: string;
  totalDurationSec: number;
  chunkCount: number;
  transcribedChunkCount: number;
  missingChunkCount: number;
  failedChunkCount: number;
  hasTranscript: boolean;
  hasNotes: boolean;
  notesRevision?: string;
  audioCleaned: boolean;
  audioBytesTotal: number;
  hasCleanableAudio?: boolean;
}

interface SpeakerStats {
  meSec: number;
  remoteSec: number;
  bothSec: number;
  timelineChunkCount: number;
}

interface MeetingDetail {
  revision?: string;
  summary: MeetingSummary;
  manifest?: {
    mode?: string;
    appTarget?: string;
    gaps?: Array<{ startSec: number; endSec: number; reason: string }>;
    failedChunkCount?: number;
    lastError?: string;
  };
  speakerStats?: SpeakerStats;
  transcribedChunkIds: string[];
  missingChunkIds: string[];
  transcript: string;
  notes: string;
  transcriptTruncated: boolean;
  notesTruncated: boolean;
  transcriptPath: string;
  notesPath: string;
}

interface SearchHit {
  id: string;
  title: string;
  mode?: string;
  createdAt: string;
  totalDurationSec: number;
  hasNotes: boolean;
  hasTranscript: boolean;
  matchedIn: string[];
  snippet: string;
}

interface GeneratingJob {
  conversationId?: string;
  startedAt: number;
  prevHasNotes: boolean;
  prevNotesRevision?: string;
}

interface CopiedPromptFallback {
  meetingId: string;
  prompt: string;
  allowCurrentChatFallback?: boolean;
  reason?: string;
}

interface AppState {
  tab: "live" | "history";
  historyDetailOpen: boolean;
  selectedMode: "dual" | "mic";
  audioRetentionPolicy: "manual" | "after_notes" | "days_7";
  hasMessageCap: boolean;
  hasOpenLinksCap: boolean;
  daemonRunning: boolean;
  daemonError: string | null;
  snapshot: RecorderSnapshot | null;
  permissions: PermissionSnapshot;
  lastAudioProbeMessage: string | null;
  recentMeetings: MeetingSummary[];
  draftTitle: string;
  actionBusy: boolean;
  bannerError: string | null;
  justStoppedMeetingId: string | null;
  activeNotesJobIds: string[];
  generatingSessions: Record<string, GeneratingJob>;
  copiedPromptBox: CopiedPromptFallback | null;
  searchQuery: string;
  searchHits: SearchHit[] | null;
  selectedMeetingId: string | null;
  selectedDetail: MeetingDetail | null;
  detailTab: "notes" | "transcript";
  confirmDeleteId: string | null;
  confirmCleanupId: string | null;
  renamingId: string | null;
  renameDraft: string;
  toastText: string | null;
}

const app = new App({ name: "anti-meeting", version: "0.3.1" }, {});

const state: AppState = {
  tab: "live",
  historyDetailOpen: false,
  selectedMode: "dual",
  audioRetentionPolicy: "manual",
  hasMessageCap: false,
  hasOpenLinksCap: false,
  daemonRunning: false,
  daemonError: null,
  snapshot: null,
  permissions: { mic: "not_determined", systemAudio: "unverified" },
  lastAudioProbeMessage: null,
  recentMeetings: [],
  draftTitle: "",
  actionBusy: false,
  bannerError: null,
  justStoppedMeetingId: null,
  activeNotesJobIds: [],
  generatingSessions: {},
  copiedPromptBox: null,
  searchQuery: "",
  searchHits: null,
  selectedMeetingId: null,
  selectedDetail: null,
  detailTab: "notes",
  confirmDeleteId: null,
  confirmCleanupId: null,
  renamingId: null,
  renameDraft: "",
  toastText: null,
};

let pollInFlight = false;
let pollTimer: number | null = null;
let searchDebounce: number | null = null;
let toastTimer: number | null = null;
let lastPollSignature = "";
let searchSeq = 0;
let detailSeq = 0;
let selectedDetailRevision: string | null = null;

function svgIcon(
  kind:
    | "mic"
    | "dual"
    | "stop"
    | "notes"
    | "shield"
    | "settings"
    | "refresh"
    | "check"
    | "close"
    | "back"
    | "chevron",
): string {
  const wrap = (inner: string) =>
    `<svg class="icon" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${inner}</svg>`;
  switch (kind) {
    case "mic":
      return wrap(
        `<rect x="5.5" y="2" width="5" height="7" rx="2.5"/><path d="M3.5 7.5a4.5 4.5 0 0 0 9 0"/><path d="M8 12v2.2"/><path d="M5.5 14.2h5"/>`,
      );
    case "dual":
      return wrap(
        `<rect x="4" y="2.5" width="4" height="6" rx="2"/><path d="M2.5 7a3.5 3.5 0 0 0 7 0"/><path d="M6 10.5V13"/><path d="M12.2 4.5v5"/><path d="M14.2 6v2"/>`,
      );
    case "stop":
      return wrap(`<rect x="4" y="4" width="8" height="8" rx="1.5" fill="currentColor" stroke="none"/>`);
    case "notes":
      return wrap(
        `<path d="M4 2.5h5.5L12.5 5.5v8a1 1 0 0 1-1 1h-7.5a1 1 0 0 1-1-1v-10a1 1 0 0 1 1-1Z"/><path d="M9.5 2.5v3h3"/><path d="M5.5 8.5h5"/><path d="M5.5 11h3.5"/>`,
      );
    case "shield":
      return wrap(
        `<path d="M8 2 13 4v4c0 3.2-2.1 5.4-5 6-2.9-.6-5-2.8-5-6V4l5-2Z"/><path d="m6 8 1.4 1.4L10.3 6.5"/>`,
      );
    case "settings":
      return wrap(
        `<circle cx="8" cy="8" r="2.2"/><path d="M8 2.2v1.3M8 12.5v1.3M2.2 8h1.3M12.5 8h1.3M3.9 3.9l.9.9M11.2 11.2l.9.9M12.1 3.9l-.9.9M4.8 11.2l-.9.9"/>`,
      );
    case "refresh":
      return wrap(
        `<path d="M13 8a5 5 0 1 1-1.3-3.4"/><path d="M13 2.8v2.5h-2.5"/>`,
      );
    case "check":
      return wrap(`<path d="m3.5 8.3 3 3 6-6.5"/>`);
    case "close":
      return wrap(`<path d="m4.5 4.5 7 7M11.5 4.5l-7 7"/>`);
    case "back":
      return wrap(`<path d="M10 3.5 5.5 8 10 12.5"/>`);
    case "chevron":
      return wrap(`<path d="M6 3.5 10.5 8 6 12.5"/>`);
  }
}

function showToast(msg: string) {
  state.toastText = msg;
  render();
  if (toastTimer !== null) window.clearTimeout(toastTimer);
  toastTimer = window.setTimeout(() => {
    state.toastText = null;
    render();
  }, 2800);
}

function formatDuration(sec: number): string {
  const total = Math.max(0, Math.floor(sec));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const pad = (n: number) => String(n).padStart(2, "0");
  return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${pad(m)}:${pad(s)}`;
}

function formatDate(iso: string): string {
  try {
    const d = new Date(iso);
    if (Number.isNaN(d.getTime())) return iso;
    const pad = (n: number) => String(n).padStart(2, "0");
    return `${d.getMonth() + 1}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
  } catch {
    return iso;
  }
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function extractToolTextError(res: { isError?: boolean; content?: Array<{ type: string; text?: string }> }): string | null {
  if (!res.isError) return null;
  const msg = res.content?.find((c) => c.type === "text")?.text;
  return msg || "操作失败";
}

function isEditingProtectedInput(): boolean {
  const activeId = document.activeElement?.id;
  return activeId === "rename-input" || activeId === "retention-policy-select";
}

function isMeetingGenerating(meetingId: string): boolean {
  return Boolean(state.generatingSessions[meetingId]) || state.activeNotesJobIds.includes(meetingId);
}

async function pollLiveOnce(options?: { autoLaunch?: boolean; forceRender?: boolean }) {
  if (pollInFlight) return;
  pollInFlight = true;
  try {
    const selectedId =
      state.tab === "history" && state.historyDetailOpen && state.selectedMeetingId
        ? state.selectedMeetingId
        : undefined;
    const trackedIds = Object.keys(state.generatingSessions);
    const res = await app.callServerTool({
      name: "app_poll_live",
      arguments: {
        autoLaunch: options?.autoLaunch === true,
        ...(selectedId ? { selectedMeetingId: selectedId } : {}),
        ...(trackedIds.length > 0 ? { trackedMeetingIds: trackedIds } : {}),
      },
    });
    const err = extractToolTextError(res as never);
    if (err) {
      state.bannerError = err;
      render();
      return;
    }
    const data = (res.structuredContent ?? {}) as {
      daemonRunning?: boolean;
      daemonError?: string | null;
      snapshot?: RecorderSnapshot | null;
      permissions?: PermissionSnapshot;
      settings?: { audioRetentionPolicy?: "manual" | "after_notes" | "days_7" };
      recentMeetings?: MeetingSummary[];
      selectedMeeting?: { summary: MeetingSummary; revision: string } | null;
      activeNotesJobIds?: string[];
      trackedSummaries?: Record<string, MeetingSummary>;
    };
    state.daemonRunning = Boolean(data.daemonRunning);
    state.daemonError = data.daemonError ?? null;
    state.snapshot = data.snapshot ?? null;
    if (data.permissions) {
      state.permissions = data.permissions;
    }
    if (
      !state.actionBusy &&
      (data.settings?.audioRetentionPolicy === "manual" ||
        data.settings?.audioRetentionPolicy === "after_notes" ||
        data.settings?.audioRetentionPolicy === "days_7")
    ) {
      state.audioRetentionPolicy = data.settings.audioRetentionPolicy;
    }
    if (Array.isArray(data.recentMeetings)) {
      state.recentMeetings = data.recentMeetings;
    }
    state.activeNotesJobIds = Array.isArray(data.activeNotesJobIds) ? data.activeNotesJobIds : [];

    const activeJobs = Object.entries(state.generatingSessions);
    let completedJobToast: string | null = null;
    for (const [jobId, job] of activeJobs) {
      const m = state.recentMeetings.find((x) => x.id === jobId);
      const selectedSummary =
        data.selectedMeeting?.summary?.id === jobId ? data.selectedMeeting.summary : undefined;
      const latestSummary = data.trackedSummaries?.[jobId] ?? selectedSummary ?? m;
      const latestHasNotes = latestSummary?.hasNotes;
      const notesRevisionChanged =
        latestSummary?.notesRevision !== undefined &&
        latestSummary.notesRevision !== job.prevNotesRevision;
      const completed =
        Boolean(latestHasNotes) && (!job.prevHasNotes || notesRevisionChanged);
      const serverCleared =
        !state.activeNotesJobIds.includes(jobId) && Date.now() - job.startedAt > 5000;
      if (completed || serverCleared) {
        delete state.generatingSessions[jobId];
        if (completed) {
          completedJobToast = "会议纪要已生成";
        }
      }
    }
    if (completedJobToast) {
      state.toastText = completedJobToast;
      if (toastTimer !== null) window.clearTimeout(toastTimer);
      toastTimer = window.setTimeout(() => {
        state.toastText = null;
        render();
      }, 2800);
    }

    if (state.tab === "history" && state.historyDetailOpen && state.selectedMeetingId) {
      if (data.selectedMeeting && data.selectedMeeting.summary?.id === state.selectedMeetingId) {
        const cur = state.selectedDetail?.summary;
        if (
          !cur ||
          cur.id !== state.selectedMeetingId ||
          selectedDetailRevision === null ||
          data.selectedMeeting.revision !== selectedDetailRevision
        ) {
          void loadMeetingDetail(state.selectedMeetingId);
        }
      } else if (Array.isArray(data.recentMeetings)) {
        const latest = data.recentMeetings.find((m) => m.id === state.selectedMeetingId);
        const cur = state.selectedDetail?.summary;
        if (
          latest &&
          (!cur ||
            cur.id !== latest.id ||
            cur.status !== latest.status ||
            cur.chunkCount !== latest.chunkCount ||
            cur.missingChunkCount !== latest.missingChunkCount ||
            cur.failedChunkCount !== latest.failedChunkCount ||
            cur.totalDurationSec !== latest.totalDurationSec ||
            cur.endedAt !== latest.endedAt ||
            cur.audioBytesTotal !== latest.audioBytesTotal ||
            cur.hasNotes !== latest.hasNotes ||
            cur.notesRevision !== latest.notesRevision ||
            cur.hasTranscript !== latest.hasTranscript ||
            cur.transcribedChunkCount !== latest.transcribedChunkCount ||
            cur.audioCleaned !== latest.audioCleaned ||
            cur.hasCleanableAudio !== latest.hasCleanableAudio ||
            cur.title !== latest.title)
        ) {
          void loadMeetingDetail(state.selectedMeetingId);
        }
      }
    }

    const sig = JSON.stringify({
      daemonRunning: state.daemonRunning,
      daemonError: state.daemonError,
      snapshot: state.snapshot,
      permissions: state.permissions,
      audioRetentionPolicy: state.audioRetentionPolicy,
      recentMeetings: state.recentMeetings,
      selectedMeetingRevision: data.selectedMeeting?.revision ?? null,
      activeNotesJobIds: state.activeNotesJobIds,
      generatingIds: Object.keys(state.generatingSessions),
    });
    if (
      (sig !== lastPollSignature || Boolean(completedJobToast) || options?.forceRender) &&
      !isEditingProtectedInput()
    ) {
      lastPollSignature = sig;
      render();
    }
  } catch (err) {
    const errMsg = err instanceof Error ? err.message : String(err);
    const sig = JSON.stringify({
      daemonRunning: state.daemonRunning,
      daemonError: errMsg,
      snapshot: state.snapshot,
      permissions: state.permissions,
      recentMeetings: state.recentMeetings,
    });
    state.daemonError = errMsg;
    if ((sig !== lastPollSignature || options?.forceRender) && !isEditingProtectedInput()) {
      lastPollSignature = sig;
      render();
    }
  } finally {
    pollInFlight = false;
  }
}

function openMeetingDetail(meetingId: string) {
  state.tab = "history";
  state.historyDetailOpen = true;
  if (typeof window.scrollTo === "function") {
    window.scrollTo({ top: 0 });
  }
  void loadMeetingDetail(meetingId);
}

function closeMeetingDetail() {
  state.historyDetailOpen = false;
  state.confirmDeleteId = null;
  state.confirmCleanupId = null;
  state.renamingId = null;
  render();
  if (typeof window.scrollTo === "function") {
    window.scrollTo({ top: 0 });
  }
}

async function loadMeetingDetail(meetingId: string) {
  const reqSeq = ++detailSeq;
  state.selectedMeetingId = meetingId;
  state.confirmDeleteId = null;
  state.confirmCleanupId = null;
  state.renamingId = null;
  render();
  try {
    const res = await app.callServerTool({
      name: "app_get_meeting",
      arguments: { meetingId },
    });
    if (reqSeq !== detailSeq) return;
    const err = extractToolTextError(res as never);
    if (err) {
      state.bannerError = err;
      render();
      return;
    }
    const loadedDetail = (res.structuredContent ?? null) as unknown as MeetingDetail | null;
    state.selectedDetail = loadedDetail;
    selectedDetailRevision = loadedDetail?.revision ?? null;
    render();
  } catch (err) {
    if (reqSeq !== detailSeq) return;
    state.bannerError = err instanceof Error ? err.message : String(err);
    render();
  }
}

function describeSystemAudioOutcome(outcome: string, otherAudioPlaying?: boolean): string {
  switch (outcome) {
    case "granted":
      return "已捕获到系统音频信号，双轨系统音权限正常。";
    case "silent_or_denied":
      return "系统音频采集为全静音：可能是「系统设置 → 隐私与安全性 → 录屏与系统录音 → 仅系统音频录制」未勾选 MeetingRecorder，也可能是系统已静音或当前应用仅打开了静音流。确认授权后请点击「重启并重检」。";
    case "tap_failed":
      return "系统音频 Tap 启动失败，请检查「仅系统音频录制」权限或默认输出设备状态。";
    case "timeout":
      return "系统音频 Tap 启动超时，尚未完成通道与权限验证，请稍后重试或重启采集服务。";
    default:
      return otherAudioPlaying
        ? "系统音频 Tap 通道就绪，但短时内未收到非静音波形，可重试检测或检查系统静音状态。"
        : "系统音频 Tap 通道就绪，当前未检测到其他应用播放音频；可播放声音后再点「检测音频权限」，或直接开始录制。";
  }
}

async function handleRequestPermission(
  kind: "mic" | "systemAudio",
  openSettings = false,
  restartDaemon = false,
) {
  if (state.actionBusy) return;
  state.actionBusy = true;
  state.bannerError = null;
  if (!openSettings) {
    state.lastAudioProbeMessage = null;
  }
  render();
  try {
    const res = await app.callServerTool({
      name: "app_request_permission",
      arguments: { kind, openSettings, ...(restartDaemon ? { restartDaemon: true } : {}) },
    });
    const err = extractToolTextError(res as never);
    if (err) {
      state.bannerError = err;
      if (kind === "systemAudio" && !openSettings) {
        state.lastAudioProbeMessage = `系统音频检测失败：${err}`;
      }
    } else {
      const data = (res.structuredContent ?? {}) as {
        prompting?: boolean;
        restarted?: boolean;
        probeOutcome?: string;
        permissions?: PermissionSnapshot;
      };
      if (data.permissions) state.permissions = data.permissions;

      if (restartDaemon) {
        if (kind === "systemAudio") {
          const probeRes = await app.callServerTool({
            name: "app_request_permission",
            arguments: { kind: "systemAudio", openSettings: false },
          });
          const probeErr = extractToolTextError(probeRes as never);
          if (probeErr) {
            state.bannerError = probeErr;
            state.lastAudioProbeMessage = `重启后系统音频检测失败：${probeErr}`;
            showToast(state.lastAudioProbeMessage);
            return;
          }
          const probeData = (probeRes.structuredContent ?? {}) as {
            probeOutcome?: string;
            permissions?: PermissionSnapshot;
          };
          if (probeData.permissions) state.permissions = probeData.permissions;
          const outcome = probeData.probeOutcome;
          if (!outcome) {
            state.lastAudioProbeMessage = "当前采集服务繁忙或未完成系统音频检测，请稍后重试。";
            showToast(state.lastAudioProbeMessage);
            return;
          }
          const msg = describeSystemAudioOutcome(outcome, state.permissions.otherAudioPlaying);
          state.lastAudioProbeMessage = msg;
          showToast(outcome === "granted" ? "采集服务已重启，系统音频权限已就绪" : msg);
        } else {
          const micState = data.permissions?.mic ?? state.permissions.mic;
          if (micState === "granted") {
            state.lastAudioProbeMessage = "采集服务已重启，麦克风权限已就绪。";
            showToast("采集服务已重启，麦克风权限已就绪");
          } else if (micState === "not_determined") {
            showToast("采集服务已重启，请点击「授权麦克风」完成授权");
          } else {
            showToast("已重启采集服务但仍无麦克风权限。请在隐私设置中关闭再开启 MeetingRecorder 后重试。");
          }
        }
      } else if (kind === "mic" && data.prompting) {
        showToast("请在系统弹窗中点击允许访问麦克风");
      } else if (kind === "systemAudio" && !openSettings) {
        const outcome = data.probeOutcome;
        if (!outcome) {
          state.lastAudioProbeMessage = "当前采集服务繁忙或未完成系统音频检测，请稍后重试。";
          showToast(state.lastAudioProbeMessage);
        } else {
          const msg = describeSystemAudioOutcome(outcome, state.permissions.otherAudioPlaying);
          state.lastAudioProbeMessage = msg;
          showToast(msg);
        }
      }
    }
  } catch (err) {
    const errMsg = err instanceof Error ? err.message : String(err);
    state.bannerError = errMsg;
    if (kind === "systemAudio" && !openSettings) {
      state.lastAudioProbeMessage = `系统音频检测失败：${errMsg}`;
    }
  } finally {
    state.actionBusy = false;
    render();
    await pollLiveOnce({ forceRender: true });
  }
}

async function handleStartRecording() {
  if (state.actionBusy) return;
  state.actionBusy = true;
  state.bannerError = null;
  state.justStoppedMeetingId = null;
  state.copiedPromptBox = null;
  state.lastAudioProbeMessage = null;
  render();
  try {
    const idempotencyKey =
      typeof crypto !== "undefined" && typeof crypto.randomUUID === "function"
        ? crypto.randomUUID()
        : `start-${Date.now()}`;
    const args: Record<string, unknown> = {
      mode: state.selectedMode,
      idempotencyKey,
    };
    if (state.draftTitle.trim()) {
      args.title = state.draftTitle.trim();
    }
    const res = await app.callServerTool({ name: "meeting_start", arguments: args });
    const err = extractToolTextError(res as never);
    if (err) {
      state.bannerError = err;
    } else {
      const data = (res.structuredContent ?? {}) as { snapshot?: RecorderSnapshot };
      if (data.snapshot) state.snapshot = data.snapshot;
      state.draftTitle = "";
    }
  } catch (err) {
    state.bannerError = err instanceof Error ? err.message : String(err);
  } finally {
    state.actionBusy = false;
    render();
    await pollLiveOnce({ forceRender: true });
  }
}

async function handleStopRecording() {
  if (state.actionBusy) return;
  const activeId = state.snapshot?.meetingId;
  state.actionBusy = true;
  state.bannerError = null;
  render();
  try {
    const res = await app.callServerTool({
      name: "meeting_stop",
      arguments: activeId ? { meetingId: activeId } : {},
    });
    const err = extractToolTextError(res as never);
    if (err) {
      state.bannerError = err;
    } else {
      const data = (res.structuredContent ?? {}) as {
        snapshot?: RecorderSnapshot;
        manifest?: { id?: string; chunks?: ChunkRecord[]; status?: string; lastError?: string };
      };
      if (data.snapshot) state.snapshot = data.snapshot;
      if (data.manifest?.id) {
        state.selectedMeetingId = data.manifest.id;
        state.selectedDetail = null;
        if (data.manifest.status !== "empty") {
          state.justStoppedMeetingId = data.manifest.id;
        }
      }
      const st = data.manifest?.status;
      if (st === "empty") {
        showToast("未录到有效语音（空录音）");
      } else if (st === "partial") {
        state.bannerError = data.manifest?.lastError || "部分切片封包失败或发生设备中断，已保存可用内容";
        showToast("已保存部分录音切片");
      } else {
        showToast("录音已安全封包");
      }
    }
  } catch (err) {
    state.bannerError = err instanceof Error ? err.message : String(err);
  } finally {
    state.actionBusy = false;
    render();
    await pollLiveOnce({ forceRender: true });
  }
}

function buildTranscribePrompt(meeting: MeetingSummary): string {
  const modeNote =
    meeting.mode === "dual"
      ? "该会议为双轨录制（含混音、我方/对方分轨与说话人时间线），请结合 timelines/*.json 标注「我方」与「对方」。"
      : "";
  const parallelHint =
    meeting.chunkCount > 4
      ? "该长会议超过 4 个切片，可按 meeting-notes 技能每 2–3 片一组使用只读子 Agent 并行转写，再由主 Agent 串行按片保存并统一称呼汇总。"
      : "";
  const resumeHint =
    meeting.transcribedChunkCount > 0 && meeting.missingChunkCount > 0
      ? `当前已完成 ${meeting.transcribedChunkCount}/${meeting.chunkCount} 个切片，请先补转剩余缺失切片后再汇总纪要。`
      : "";
  // Pass only validated meetingId, static mode tag & numeric counts; never interpolate untrusted title strings into user prompt.
  return [
    `请使用 meeting-notes 技能整理会议 \`${meeting.id}\`（共 ${meeting.chunkCount} 个切片）。`,
    modeNote,
    parallelHint,
    resumeHint,
    `请先调用 \`meeting_get({ meetingId: "${meeting.id}" })\` 获取最新切片路径与断点进度，逐片读取可用音频转写并按片保存，最后保存完整逐字稿与会议纪要。`,
  ]
    .filter(Boolean)
    .join(" ");
}

const MISSING_TOOL_RE =
  /(?:tool\s+['"`]?app_notes_job['"`]?\s+not\s+found|unknown\s+tool(?:\s*[:(]?\s*['"`]?app_notes_job['"`]?)?|method\s+not\s+found|(?<![0-9])-32601(?![0-9]))/i;

function isMissingNotesJobToolError(errOrText: unknown): boolean {
  if (typeof errOrText === "string") {
    return MISSING_TOOL_RE.test(errOrText);
  }
  const errCode = (errOrText as { code?: unknown } | null)?.code;
  const errMsg = errOrText instanceof Error ? errOrText.message : String(errOrText ?? "");
  return errCode === -32601 || MISSING_TOOL_RE.test(errMsg);
}

async function handleSendToAgent(
  meeting: MeetingSummary,
  options?: { target?: "new" | "current" },
) {
  if (state.actionBusy || isMeetingGenerating(meeting.id)) return;
  const target = options?.target ?? "new";
  state.actionBusy = true;
  state.bannerError = null;
  render();
  const prompt = buildTranscribePrompt(meeting);
  const claimToken =
    typeof crypto !== "undefined" && typeof crypto.randomUUID === "function"
      ? crypto.randomUUID()
      : `job-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
  let claimedLock = false;
  let claimedJob: GeneratingJob | undefined;

  try {
    try {
      const claimRes = await app.callServerTool(
        {
          name: "app_notes_job",
          arguments: { action: "claim", meetingId: meeting.id, clientJobId: claimToken },
        },
        { timeout: 5000 },
      );
      const claimErr = extractToolTextError(claimRes as never);
      if (claimErr) {
        if (!isMissingNotesJobToolError(claimErr)) {
          state.bannerError = claimErr;
          return;
        }
      } else {
        const claimData = (claimRes.structuredContent ?? {}) as {
          claimed?: boolean;
          job?: GeneratingJob;
        };
        if (claimData.claimed === false) {
          if (!state.activeNotesJobIds.includes(meeting.id)) {
            state.activeNotesJobIds = [...state.activeNotesJobIds, meeting.id];
          }
          showToast("该会议已在另一会话中生成纪要");
          return;
        }
        if (claimData.claimed !== true) {
          await app
            .callServerTool(
              {
                name: "app_notes_job",
                arguments: { action: "release", meetingId: meeting.id, clientJobId: claimToken },
              },
              { timeout: 2500 },
            )
            .catch(() => {});
          state.bannerError = "任务占锁返回异常，未发送生成请求，请稍后重试。";
          showToast("任务占锁状态异常，请重试");
          return;
        }
        claimedLock = true;
        claimedJob = claimData.job;
      }
    } catch (claimErr) {
      if (!isMissingNotesJobToolError(claimErr)) {
        // Never bypass cross-panel mutual exclusion on lock timeout or unknown lock error.
        await app
          .callServerTool(
            {
              name: "app_notes_job",
              arguments: { action: "release", meetingId: meeting.id, clientJobId: claimToken },
            },
            { timeout: 2500 },
          )
          .catch(() => {});
        const detail = claimErr instanceof Error ? claimErr.message : String(claimErr);
        state.bannerError = `确认生成任务状态超时或失败（${detail}），请稍后重试。`;
        showToast("任务锁确认超时，请稍后重试");
        return;
      }
      // Best-effort cross-panel lock: only skip when server doesn't implement app_notes_job.
    }

    const messageParams = {
      role: "user" as const,
      content: [{ type: "text" as const, text: prompt }],
      ...(target === "new"
        ? { _meta: { "com.google.antigravity/message": { target: "new" } } }
        : {}),
    };

    const res = await app.sendMessage(
      messageParams as Parameters<typeof app.sendMessage>[0],
      { timeout: 20000 },
    );

    if (res?.isError) {
      const contentText = (res as { content?: Array<{ type?: string; text?: string }> })
        .content?.find((c) => c.type === "text" && typeof c.text === "string" && c.text.trim())
        ?.text?.trim();
      const rawMsg =
        typeof (res as { message?: unknown }).message === "string"
          ? (res as { message: string }).message.trim()
          : "";
      const detail = contentText || rawMsg;
      throw new Error(detail ? `host rejected ui/message (${detail})` : "host rejected ui/message");
    }

    const resMeta = (res as { _meta?: Record<string, { conversationId?: string }> } | undefined)
      ?._meta?.["com.google.antigravity/message"];
    const conversationId =
      typeof resMeta?.conversationId === "string" ? resMeta.conversationId : undefined;

    state.generatingSessions[meeting.id] = {
      conversationId,
      startedAt: claimedJob?.startedAt ?? Date.now(),
      prevHasNotes: claimedJob?.prevHasNotes ?? meeting.hasNotes,
      prevNotesRevision: claimedJob?.prevNotesRevision ?? meeting.notesRevision,
    };
    if (!state.activeNotesJobIds.includes(meeting.id)) {
      state.activeNotesJobIds = [...state.activeNotesJobIds, meeting.id];
    }
    state.copiedPromptBox = null;

    showToast(
      target === "new"
        ? conversationId
          ? "已开启独立会话生成纪要"
          : "已在新独立会话中开始生成纪要"
        : "已发送至当前对话生成纪要",
    );
  } catch (err) {
    const errDetail = err instanceof Error ? err.message : String(err);
    if (claimedLock) {
      let shouldRemoveLocalActive = true;
      try {
        const releaseRes = await app.callServerTool(
          {
            name: "app_notes_job",
            arguments: { action: "release", meetingId: meeting.id, clientJobId: claimToken },
          },
          { timeout: 2500 },
        );
        const releaseErr = extractToolTextError(releaseRes as never);
        const releaseData = (releaseRes.structuredContent ?? {}) as { released?: boolean };
        if (!releaseErr && releaseData.released === false) {
          shouldRemoveLocalActive = false;
        }
      } catch {
        // Best-effort release; remove local optimistic state if self-owned lock cleanup fails.
      }
      if (shouldRemoveLocalActive) {
        state.activeNotesJobIds = state.activeNotesJobIds.filter((id) => id !== meeting.id);
      }
    }
    await copyMarkdownText(prompt, true);
    state.copiedPromptBox = {
      meetingId: meeting.id,
      prompt,
      allowCurrentChatFallback: target === "new" && state.hasMessageCap,
      reason: state.hasMessageCap
        ? `独立后台会话触发失败（${errDetail}），已复制生成指令；你可直接粘贴到新对话，或点击「改在当前对话生成」。`
        : `当前视图暂不支持自动发送消息（${errDetail}）；请在右侧边栏「+ → anti-meeting」中点击「生成纪要」，或粘贴已复制指令到任意对话。`,
    };
    showToast("暂无法直连新会话，已自动复制生成指令");
  } finally {
    state.actionBusy = false;
    render();
  }
}

async function handleChangeRetentionPolicy(policy: "manual" | "after_notes" | "days_7") {
  if (state.actionBusy) return;
  const prev = state.audioRetentionPolicy;
  state.audioRetentionPolicy = policy;
  state.actionBusy = true;
  state.bannerError = null;
  render();
  try {
    const res = await app.callServerTool({
      name: "app_set_settings",
      arguments: { audioRetentionPolicy: policy },
    });
    const err = extractToolTextError(res as never);
    if (err) {
      state.audioRetentionPolicy = prev;
      state.bannerError = err;
    } else {
      const data = (res.structuredContent ?? {}) as {
        settings?: { audioRetentionPolicy?: "manual" | "after_notes" | "days_7" };
        cleanedCount?: number;
        freedBytes?: number;
      };
      if (
        data.settings?.audioRetentionPolicy === "manual" ||
        data.settings?.audioRetentionPolicy === "after_notes" ||
        data.settings?.audioRetentionPolicy === "days_7"
      ) {
        state.audioRetentionPolicy = data.settings.audioRetentionPolicy;
      }
      const cleanedCount = data.cleanedCount ?? 0;
      if (cleanedCount > 0) {
        showToast(`策略已保存，已自动清理 ${cleanedCount} 场已完成会议原音频（释放 ${formatBytes(data.freedBytes ?? 0)}）`);
      } else {
        showToast("原音频留存策略已更新");
      }
      await pollLiveOnce({ forceRender: true });
      if (state.historyDetailOpen && state.selectedMeetingId) {
        await loadMeetingDetail(state.selectedMeetingId);
      }
    }
  } catch (err) {
    state.audioRetentionPolicy = prev;
    state.bannerError = err instanceof Error ? err.message : String(err);
  } finally {
    state.actionBusy = false;
    render();
  }
}

async function handleCleanupAudio(meetingId: string) {
  if (state.actionBusy) return;
  state.actionBusy = true;
  state.confirmCleanupId = null;
  state.bannerError = null;
  render();
  try {
    const res = await app.callServerTool({
      name: "app_cleanup_audio",
      arguments: { meetingId },
    });
    const err = extractToolTextError(res as never);
    if (err) {
      state.bannerError = err;
    } else {
      const data = (res.structuredContent ?? {}) as { freedBytes?: number };
      showToast(`已清理原音频，释放 ${formatBytes(data.freedBytes ?? 0)}`);
      await pollLiveOnce({ forceRender: true });
      if (state.selectedMeetingId === meetingId) {
        await loadMeetingDetail(meetingId);
      }
    }
  } catch (err) {
    state.bannerError = err instanceof Error ? err.message : String(err);
  } finally {
    state.actionBusy = false;
    render();
  }
}

async function handleDeleteMeeting(meetingId: string) {
  if (state.actionBusy) return;
  state.actionBusy = true;
  state.confirmDeleteId = null;
  state.bannerError = null;
  render();
  try {
    const res = await app.callServerTool({
      name: "app_delete_meeting",
      arguments: { meetingId },
    });
    const err = extractToolTextError(res as never);
    if (err) {
      state.bannerError = err;
    } else {
      showToast("会议已删除");
      delete state.generatingSessions[meetingId];
      if (state.selectedMeetingId === meetingId) {
        state.selectedMeetingId = null;
        state.selectedDetail = null;
        state.historyDetailOpen = false;
      }
      await pollLiveOnce({ forceRender: true });
    }
  } catch (err) {
    state.bannerError = err instanceof Error ? err.message : String(err);
  } finally {
    state.actionBusy = false;
    render();
  }
}

async function handleSaveRename(meetingId: string) {
  const title = state.renameDraft.trim();
  if (!title || state.actionBusy) return;
  state.actionBusy = true;
  state.bannerError = null;
  render();
  try {
    const res = await app.callServerTool({
      name: "app_rename_meeting",
      arguments: { meetingId, title },
    });
    const err = extractToolTextError(res as never);
    if (err) {
      state.bannerError = err;
    } else {
      state.renamingId = null;
      showToast("标题已更新");
      await pollLiveOnce({ forceRender: true });
      if (state.selectedMeetingId === meetingId) {
        await loadMeetingDetail(meetingId);
      }
    }
  } catch (err) {
    state.bannerError = err instanceof Error ? err.message : String(err);
  } finally {
    state.actionBusy = false;
    render();
  }
}

async function handleSearch(query: string) {
  state.searchQuery = query;
  const seq = ++searchSeq;
  if (searchDebounce !== null) window.clearTimeout(searchDebounce);
  const trimmed = query.trim();
  if (!trimmed) {
    state.searchHits = null;
    render();
    return;
  }
  searchDebounce = window.setTimeout(async () => {
    try {
      const res = await app.callServerTool({
        name: "meeting_search",
        arguments: { query: trimmed, limit: 30 },
      });
      if (seq !== searchSeq) return;
      const err = extractToolTextError(res as never);
      if (!err) {
        const data = (res.structuredContent ?? {}) as { hits?: SearchHit[] };
        state.searchHits = data.hits ?? [];
        render();
      }
    } catch {
      // ignore transient search error
    }
  }, 220);
}

async function copyMarkdownText(text: string, silent = false): Promise<boolean> {
  try {
    if (navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(text);
      if (!silent) showToast("已复制到剪贴板");
      return true;
    }
  } catch {
    // Fallback below
  }
  const ta = document.createElement("textarea");
  ta.value = text;
  ta.style.position = "fixed";
  ta.style.opacity = "0";
  document.body.appendChild(ta);
  ta.select();
  const ok = document.execCommand("copy");
  document.body.removeChild(ta);
  if (!silent) {
    showToast(ok ? "已复制到剪贴板" : "复制失败，请手动选中文本复制");
  }
  return ok;
}

function renderMeetingStatusBadge(m: MeetingSummary): string {
  if (m.status === "recording") return `<span class="badge partial">录制中</span>`;
  if (m.status === "finalizing") return `<span class="badge partial">封包中</span>`;
  if (m.status === "empty") return `<span class="badge">空录音</span>`;
  if (isMeetingGenerating(m.id)) {
    return `<span class="badge generating">独立会话生成中</span>`;
  }
  if (m.status === "partial" || m.failedChunkCount > 0) {
    return `<span class="badge partial">部分完成</span>`;
  }
  if (m.hasNotes && m.missingChunkCount === 0) {
    return `<span class="badge done">已完成纪要</span>`;
  }
  if (m.transcribedChunkCount > 0) {
    return `<span class="badge partial">已转写 ${m.transcribedChunkCount}/${m.chunkCount}</span>`;
  }
  return `<span class="badge">待转写 (${m.chunkCount} 片)</span>`;
}

function renderSystemStatusBadge(sysStatus: string): string {
  if (sysStatus === "granted") {
    return `<span class="sys-pill granted">系统音频已捕获</span>`;
  }
  if (sysStatus === "silent_or_denied") {
    return `<span class="sys-pill warn">系统音频静音/未授权</span>`;
  }
  if (sysStatus === "tap_failed") {
    return `<span class="sys-pill error">系统音频降级</span>`;
  }
  return `<span class="sys-pill">等待系统音</span>`;
}

function formatGapReason(reason: string): string {
  switch (reason) {
    case "audio_device_changed":
      return "音频设备切换";
    case "audio_device_lost":
      return "音频设备中断";
    case "system_audio_tap_failed":
      return "系统音频捕获失败";
    case "system_audio_reconnecting":
      return "系统音频重连";
    case "system_audio_device_changed":
      return "系统输出设备切换";
    case "system_audio_silent":
      return "系统音频无信号";
    default:
      return reason || "未知原因";
  }
}

function transcribeButtonLabel(m: MeetingSummary): string {
  if (isMeetingGenerating(m.id)) {
    return "独立会话生成中...";
  }
  if (m.transcribedChunkCount > 0 && m.missingChunkCount > 0) {
    return `补转缺失 (${m.transcribedChunkCount}/${m.chunkCount})`;
  }
  return m.hasNotes ? "重新生成纪要" : "生成纪要";
}

function renderLiveTab(): string {
  const snap = state.snapshot;
  const recState = snap?.state ?? "idle";
  const isRecording = recState === "recording";
  const isFinalizing = recState === "finalizing" || recState === "starting";
  const effectiveMode: "dual" | "mic" =
    (isRecording || isFinalizing) && (snap?.mode === "mic" || snap?.mode === "dual")
      ? snap.mode
      : state.selectedMode;
  const micPerm = state.permissions.mic;
  const sysStatus =
    (isRecording || isFinalizing) && snap?.systemAudioStatus
      ? snap.systemAudioStatus
      : state.permissions.systemAudio;
  const probeDisabled = state.actionBusy || isRecording || isFinalizing;

  let permBanner = "";
  if (state.daemonRunning && micPerm !== "granted") {
    const isDenied = micPerm === "denied" || micPerm === "restricted";
    const guidance = isDenied
      ? `当前状态：${escapeHtml(micPerm)}。请在「系统设置 → 隐私与安全性 → 麦克风」中勾选 MeetingRecorder；若开关已是开启状态（常见于重签后），请先关闭再重新开启，然后点击「重启并重检权限」。`
      : `当前状态：${escapeHtml(micPerm)}。请点击「授权麦克风」，或在系统设置麦克风列表中勾选 MeetingRecorder。`;
    permBanner = `
      <div class="banner">
        <div>
          <strong>需要麦克风权限（MeetingRecorder）</strong>
          <div class="muted-note">${guidance}</div>
        </div>
        <div class="item-actions">
          ${
            isDenied
              ? `<button class="btn btn-primary btn-sm" data-action="open-mic-settings" ${state.actionBusy ? "disabled" : ""}>打开隐私设置</button>
                 <button class="btn btn-sm" data-action="recheck-mic" ${probeDisabled ? "disabled" : ""}>${svgIcon("refresh")}重启并重检权限</button>`
              : `<button class="btn btn-primary btn-sm" data-action="request-mic" ${state.actionBusy ? "disabled" : ""}>授权麦克风</button>
                 <button class="btn btn-sm" data-action="open-mic-settings" ${state.actionBusy ? "disabled" : ""}>打开隐私设置</button>`
          }
        </div>
      </div>
    `;
  }

  let sysPermBanner = "";
  if (
    state.daemonRunning &&
    effectiveMode === "dual" &&
    (sysStatus === "silent_or_denied" || sysStatus === "tap_failed")
  ) {
    const isFailed = sysStatus === "tap_failed";
    sysPermBanner = `
      <div class="banner ${isFailed ? "error" : ""}">
        <div>
          <strong>${
            isFailed
              ? "系统音频捕获失败（已自动降级为仅麦克风）"
              : "未检测到系统音频（输出静音或未授权）"
          }</strong>
          <div class="muted-note">${
            isFailed
              ? "系统音频 Tap 启动或重连失败，本次保留我方麦克风声轨，请检查「仅系统音频录制」权限或输出设备。"
              : "检测到其他应用可能正在播音但系统轨无声。请确认未静音，并在「系统设置 → 隐私与安全性 → 录屏与系统录音 → 仅系统音频录制」勾选 MeetingRecorder。"
          }</div>
        </div>
        <div class="item-actions">
          ${
            !isRecording && !isFinalizing
              ? `<button class="btn btn-primary btn-sm" data-action="request-sysaudio" ${state.actionBusy ? "disabled" : ""}>${svgIcon("shield")}重新检测</button>
                 <button class="btn btn-sm" data-action="recheck-sysaudio" ${state.actionBusy ? "disabled" : ""}>${svgIcon("refresh")}重启并重检</button>`
              : ""
          }
          <button class="btn btn-sm" data-action="open-sysaudio-settings" ${state.actionBusy ? "disabled" : ""}>打开隐私设置</button>
        </div>
      </div>
    `;
  }

  const micDotClass = micPerm === "granted" ? "ok" : micPerm === "not_determined" ? "neutral" : "err";
  const micLabel = micPerm === "granted" ? "已授权" : micPerm === "not_determined" ? "待授权" : "未授权";
  const sysDotClass =
    sysStatus === "granted"
      ? "ok"
      : sysStatus === "silent_or_denied"
        ? "warn"
        : sysStatus === "tap_failed"
          ? "err"
          : "neutral";
  const sysDiagLabel =
    sysStatus === "granted"
      ? "已验证有声"
      : sysStatus === "silent_or_denied"
        ? "静音或未授权"
        : sysStatus === "tap_failed"
          ? "Tap 失败"
          : state.permissions.tapReady
            ? "通道就绪 · 待有声验证"
            : "待检测";

  const permStripHtml = state.daemonRunning
    ? `
      <div class="perm-strip" data-perm-strip="true">
        <div class="perm-strip-head">
          <span class="perm-strip-title">音频权限与设备</span>
          <div class="item-actions">
            ${
              effectiveMode === "dual"
                ? `<button class="btn btn-sm" data-action="request-sysaudio" ${probeDisabled ? "disabled" : ""}>${svgIcon("shield")}检测音频权限</button>
                   <button class="btn btn-sm btn-ghost" data-action="recheck-sysaudio" ${probeDisabled ? "disabled" : ""} title="重启采集服务后重新检测">${svgIcon("refresh")}重启并重检</button>
                   <button class="btn btn-sm btn-ghost" data-action="open-sysaudio-settings" ${state.actionBusy ? "disabled" : ""} title="系统隐私设置">${svgIcon("settings")}隐私设置</button>`
                : `<button class="btn btn-sm btn-ghost" data-action="recheck-mic" ${probeDisabled ? "disabled" : ""} title="重启采集服务并重检麦克风">${svgIcon("refresh")}重启并重检</button>
                   <button class="btn btn-sm btn-ghost" data-action="open-mic-settings" ${state.actionBusy ? "disabled" : ""} title="麦克风隐私设置">${svgIcon("settings")}隐私设置</button>`
            }
          </div>
        </div>
        <div class="perm-rows">
          <div class="perm-row">
            <span class="perm-row-left">
              <span class="dot ${micDotClass}"></span>
              <span>麦克风</span>
              <span class="perm-device">${escapeHtml(snap?.inputDeviceName || "默认输入设备")}</span>
            </span>
            <span class="perm-row-right">
              <span class="badge ${micPerm === "granted" ? "done" : ""}">${micLabel}</span>
            </span>
          </div>
          ${
            effectiveMode === "dual"
              ? `
                <div class="perm-row">
                  <span class="perm-row-left">
                    <span class="dot ${sysDotClass}"></span>
                    <span>系统音频</span>
                    <span class="perm-device">${escapeHtml(snap?.outputDeviceName || "默认输出设备")}</span>
                  </span>
                  <span class="perm-row-right">
                    ${
                      state.permissions.otherAudioPlaying
                        ? `<span class="badge">检测到播音</span>`
                        : ""
                    }
                    <span class="badge ${sysStatus === "granted" ? "done" : sysStatus === "silent_or_denied" ? "partial" : ""}">${sysDiagLabel}</span>
                  </span>
                </div>
              `
              : ""
          }
        </div>
        ${
          state.lastAudioProbeMessage
            ? `<div class="perm-note">
                 <span>${escapeHtml(state.lastAudioProbeMessage)}</span>
                 <button class="btn btn-sm btn-ghost" data-action="dismiss-probe-msg" aria-label="关闭提示">${svgIcon("close")}</button>
               </div>`
            : ""
        }
      </div>
    `
    : "";

  const mePct = Math.round(Math.min(1, Math.max(0, snap?.meLevel ?? 0)) * 100);
  const remotePct = Math.round(Math.min(1, Math.max(0, snap?.remoteLevel ?? 0)) * 100);

  const justStoppedMeeting = state.justStoppedMeetingId
    ? state.recentMeetings.find(
        (m) =>
          m.id === state.justStoppedMeetingId &&
          m.chunkCount > 0 &&
          m.status !== "recording" &&
          m.status !== "finalizing" &&
          m.status !== "empty",
      )
    : undefined;

  const postStopCtaHtml = justStoppedMeeting
    ? `
      <div class="cta-card">
        <div class="cta-card-head">
          <strong>录音已封包：${escapeHtml(justStoppedMeeting.title)}</strong>
          <span class="muted-note">${formatDuration(justStoppedMeeting.totalDurationSec)} · ${justStoppedMeeting.chunkCount} 片</span>
        </div>
        <div class="item-actions">
          <button class="btn btn-primary btn-sm" data-action="transcribe" data-id="${escapeHtml(justStoppedMeeting.id)}" ${state.actionBusy || isMeetingGenerating(justStoppedMeeting.id) ? "disabled" : ""}>
            ${svgIcon("notes")}${isMeetingGenerating(justStoppedMeeting.id) ? "独立会话生成中..." : "新建会话生成纪要"}
          </button>
          <button class="btn btn-sm" data-action="open-detail" data-id="${escapeHtml(justStoppedMeeting.id)}">查看详情</button>
          <button class="btn btn-sm btn-ghost" data-action="dismiss-cta">收起</button>
        </div>
      </div>
    `
    : "";

  const recentHtml =
    state.recentMeetings.length === 0
      ? `<div class="empty-state">还没有会议记录，点击上方按钮开始第一次录制。</div>`
      : state.recentMeetings
          .slice(0, 8)
          .map((m) => {
            const canTranscribe =
              m.chunkCount > 0 &&
              m.status !== "recording" &&
              m.status !== "finalizing" &&
              m.status !== "empty";
            const actionLabel = transcribeButtonLabel(m);
            return `
              <div class="meeting-item clickable" data-action="open-detail" data-id="${escapeHtml(m.id)}">
                <div class="meeting-item-top">
                  <div class="meeting-title">${escapeHtml(m.title)}</div>
                  <div class="item-actions">
                    <span class="badge">${m.mode === "dual" ? "双轨" : "仅麦"}</span>
                    ${renderMeetingStatusBadge(m)}
                  </div>
                </div>
                <div class="meeting-meta">
                  <span>${escapeHtml(formatDate(m.createdAt))}</span>
                  <span>${formatDuration(m.totalDurationSec)}</span>
                  <span>${m.chunkCount} 片 · ${formatBytes(m.audioBytesTotal)}</span>
                </div>
                <div class="item-actions">
                  ${
                    canTranscribe
                      ? `<button class="btn btn-primary btn-sm" data-action="transcribe" data-id="${escapeHtml(m.id)}" ${state.actionBusy || isMeetingGenerating(m.id) ? "disabled" : ""}>${svgIcon("notes")}${actionLabel}</button>`
                      : ""
                  }
                  <button class="btn btn-sm" data-action="open-detail" data-id="${escapeHtml(m.id)}">查看详情</button>
                </div>
              </div>
            `;
          })
          .join("");

  const liveGaps = Array.isArray(snap?.gaps) ? snap.gaps : [];
  const liveFailedChunks =
    typeof snap?.failedChunkCount === "number" && snap.failedChunkCount > 0
      ? snap.failedChunkCount
      : 0;
  let liveGapBanner = "";
  if ((isRecording || isFinalizing) && (liveGaps.length > 0 || liveFailedChunks > 0)) {
    const latestGap = liveGaps.length > 0 ? liveGaps[liveGaps.length - 1] : null;
    const summaryParts: string[] = [];
    if (liveGaps.length > 0 && latestGap) {
      summaryParts.push(
        `已记录 ${liveGaps.length} 处音频缺口（最近：${formatDuration(latestGap.startSec)}–${formatDuration(latestGap.endSec)}，${escapeHtml(formatGapReason(latestGap.reason))}）`,
      );
    }
    if (liveFailedChunks > 0) {
      summaryParts.push(`${liveFailedChunks} 个切片写入失败`);
    }
    liveGapBanner = `
      <div class="banner" data-live-gap-banner="true">
        <div>
          <strong>录制过程中发生音频缺口</strong>
          <div class="muted-note">${summaryParts.join("；")}。已保存或恢复后的其余音频会继续录制并在纪要中如实标注。</div>
        </div>
      </div>
    `;
  }

  return `
    ${permBanner}
    ${sysPermBanner}
    ${liveGapBanner}
    ${
      state.daemonError && !state.daemonRunning
        ? `<div class="banner error"><div><strong>采集守护进程未就绪</strong><div class="muted-note">${escapeHtml(state.daemonError)}</div></div><button class="btn btn-sm" data-action="retry-poll">重试连接</button></div>`
        : ""
    }
    <div class="card">
      <div class="section-title">
        <span>采集方式</span>
      </div>
      <div class="mode-grid">
        <button
          type="button"
          class="mode-card ${effectiveMode === "dual" ? "selected" : ""}"
          data-action="select-mode"
          data-mode="dual"
          ${isRecording || isFinalizing ? "disabled" : ""}
        >
          <span class="mode-name-row">
            <span class="mode-name">${svgIcon("dual")}双轨录制</span>
            ${effectiveMode === "dual" ? svgIcon("check") : ""}
          </span>
          <span class="mode-desc">系统音频 + 麦克风（Zoom / 飞书 / 腾讯 / 浏览器）</span>
        </button>
        <button
          type="button"
          class="mode-card ${effectiveMode === "mic" ? "selected" : ""}"
          data-action="select-mode"
          data-mode="mic"
          ${isRecording || isFinalizing ? "disabled" : ""}
        >
          <span class="mode-name-row">
            <span class="mode-name">${svgIcon("mic")}仅麦克风</span>
            ${effectiveMode === "mic" ? svgIcon("check") : ""}
          </span>
          <span class="mode-desc">仅采集麦克风（线下讨论 / 语音笔记）</span>
        </button>
      </div>
      ${permStripHtml}
      ${
        !isRecording && !isFinalizing
          ? `<div class="input-row">
               <input id="draft-title-input" class="text-input" type="text" maxlength="500" placeholder="可选：输入会议标题（留空按时间命名）" value="${escapeHtml(state.draftTitle)}" />
             </div>`
          : ""
      }
      <button
        type="button"
        class="btn record-action-btn ${isRecording ? "btn-danger" : "btn-primary"}"
        data-action="${isRecording ? "stop" : "start"}"
        ${state.actionBusy || isFinalizing ? "disabled" : ""}
      >
        ${
          recState === "starting"
            ? effectiveMode === "dual"
              ? "正在启动双轨采集..."
              : "正在启动麦克风..."
            : recState === "finalizing"
              ? "正在封包音频切片..."
              : isRecording
                ? `${svgIcon("stop")}停止录制并封包`
                : effectiveMode === "dual"
                  ? `${svgIcon("dual")}开始双轨录制`
                  : `${svgIcon("mic")}开始仅麦克风录制`
        }
      </button>
      ${
        isRecording || isFinalizing
          ? `
            <div class="live-metrics">
              <div class="timer-row">
                <span class="timer-value">${formatDuration(snap?.elapsedSec ?? 0)}</span>
                <span class="muted-note">已提交 ${snap?.committedChunkCount ?? 0} 个切片（~5 分钟/片）</span>
              </div>
              <div class="meter-group">
                <div class="meter-row">
                  <div class="meter-label-row">
                    <span>我方（麦克风）</span>
                    <span>${mePct}%</span>
                  </div>
                  <div class="meter-track"><div class="meter-fill" style="width:${mePct}%"></div></div>
                </div>
                ${
                  effectiveMode === "dual"
                    ? `
                      <div class="meter-row">
                        <div class="meter-label-row">
                          <span>对方（系统音频）</span>
                          <span class="item-actions">${renderSystemStatusBadge(sysStatus)}<span>${remotePct}%</span></span>
                        </div>
                        <div class="meter-track"><div class="meter-fill remote" style="width:${remotePct}%"></div></div>
                      </div>
                    `
                    : ""
                }
              </div>
              <div class="muted-note">${escapeHtml(snap?.title || "")}</div>
            </div>
          `
          : `<div class="muted-note">录音在后台独立运行，可随时继续或切换其他 Antigravity 会话；点击「生成纪要」会自动在新独立会话中转写汇总。</div>`
      }
    </div>
    ${postStopCtaHtml}
    <div class="card">
      <div class="section-title">
        <span>最近录制</span>
        <button class="btn btn-sm btn-ghost" data-action="switch-history">全部 (${state.recentMeetings.length})</button>
      </div>
      <div class="meeting-list">${recentHtml}</div>
    </div>
  `;
}

function renderHistoryTab(): string {
  if (state.historyDetailOpen && state.selectedMeetingId) {
    let detailHtml = `<div class="empty-state">正在加载会议详情...</div>`;
    const detail = state.selectedDetail;
    if (detail && detail.summary.id === state.selectedMeetingId) {
      const s = detail.summary;
      const isRenaming = state.renamingId === s.id;
      const isConfirmingDel = state.confirmDeleteId === s.id;
      const isConfirmingClean = state.confirmCleanupId === s.id;
      const activeText = state.detailTab === "notes" ? detail.notes : detail.transcript;
      const isActiveTruncated =
        state.detailTab === "notes" ? detail.notesTruncated : detail.transcriptTruncated;
      const activeDiskPath = state.detailTab === "notes" ? detail.notesPath : detail.transcriptPath;
      const isRecordingThis =
        (state.snapshot?.meetingId === s.id &&
          (state.snapshot?.state === "recording" || state.snapshot?.state === "finalizing")) ||
        s.status === "recording" ||
        s.status === "finalizing";
      const needsCleanupConfirm = s.missingChunkCount > 0 || !s.hasNotes;
      const gaps = detail.manifest?.gaps ?? [];
      const failedCount = detail.manifest?.failedChunkCount ?? s.failedChunkCount;
      const stats = detail.speakerStats;
      const actionLabel = transcribeButtonLabel(s);

      detailHtml = `
      <div class="detail-header">
        ${
          isRenaming
            ? `
              <div class="input-row">
                <input id="rename-input" class="text-input" type="text" maxlength="500" value="${escapeHtml(state.renameDraft)}" />
                <button class="btn btn-primary btn-sm" data-action="save-rename" data-id="${escapeHtml(s.id)}">保存</button>
                <button class="btn btn-sm" data-action="cancel-rename">取消</button>
              </div>
            `
            : `
              <div class="meeting-item-top">
                <div class="item-actions">
                  <div style="font-size:15px;font-weight:600;">${escapeHtml(s.title)}</div>
                  <span class="badge">${s.mode === "dual" ? "双轨录制" : "仅麦克风"}</span>
                  ${isMeetingGenerating(s.id) ? `<span class="badge generating">独立会话生成中</span>` : ""}
                </div>
                ${
                  !isRecordingThis
                    ? `<button class="btn btn-sm" data-action="start-rename" data-id="${escapeHtml(s.id)}" data-title="${escapeHtml(s.title)}">重命名</button>`
                    : ""
                }
              </div>
            `
        }
        <div class="meeting-meta">
          <span>ID: <code>${escapeHtml(s.id)}</code></span>
          <span>${escapeHtml(formatDate(s.createdAt))}</span>
          <span>时长 ${formatDuration(s.totalDurationSec)}</span>
          <span>切片 ${s.transcribedChunkCount}/${s.chunkCount}</span>
          <span>音频 ${s.audioCleaned && s.hasCleanableAudio !== true ? "已清理" : formatBytes(s.audioBytesTotal)}</span>
          ${
            stats
              ? `<span>发言分布 我方 ${formatDuration(stats.meSec)} · 对方 ${formatDuration(stats.remoteSec)} · 重叠 ${formatDuration(stats.bothSec)}</span>`
              : ""
          }
        </div>
        ${
          s.status === "partial" || gaps.length > 0 || failedCount > 0
            ? `<div class="banner"><div><strong>部分完成（存在声轨或切片缺口）</strong><div class="muted-note">${gaps.length > 0 ? `缺口 ${gaps.length} 处` : ""}${gaps.length > 0 && failedCount > 0 ? " · " : ""}${failedCount > 0 ? `异常切片 ${failedCount} 个` : ""}${detail.manifest?.lastError ? ` · ${escapeHtml(detail.manifest.lastError)}` : ""}</div></div></div>`
            : ""
        }
        <div class="item-actions">
          <div class="tab-group">
            <button class="tab-btn ${state.detailTab === "notes" ? "active" : ""}" data-action="detail-tab" data-tab="notes">会议纪要</button>
            <button class="tab-btn ${state.detailTab === "transcript" ? "active" : ""}" data-action="detail-tab" data-tab="transcript">逐字稿</button>
          </div>
          <button class="btn btn-sm" data-action="copy-active" ${!activeText ? "disabled" : ""}>复制 Markdown</button>
          ${
            ((!s.audioCleaned && s.audioBytesTotal > 0) || s.hasCleanableAudio === true) && !isRecordingThis
              ? isConfirmingClean
                ? `<button class="btn btn-danger btn-sm" data-action="confirm-cleanup" data-id="${escapeHtml(s.id)}">确认清理 ${s.chunkCount} 组原音</button>
                   <button class="btn btn-sm" data-action="cancel-cleanup">取消</button>`
                : `<button class="btn btn-sm" data-action="${needsCleanupConfirm ? "ask-cleanup" : "confirm-cleanup"}" data-id="${escapeHtml(s.id)}" ${state.actionBusy ? "disabled" : ""}>清理原音频 (${formatBytes(s.audioBytesTotal)})</button>`
              : ""
          }
          ${
            !isRecordingThis
              ? isConfirmingDel
                ? `<button class="btn btn-danger btn-sm" data-action="confirm-delete" data-id="${escapeHtml(s.id)}">确认删除</button>
                   <button class="btn btn-sm" data-action="cancel-delete">取消</button>`
                : `<button class="btn btn-sm" data-action="ask-delete" data-id="${escapeHtml(s.id)}">删除</button>`
              : ""
          }
          ${
            s.chunkCount > 0 && !isRecordingThis && s.status !== "empty"
              ? `<button class="btn btn-primary btn-sm" data-action="transcribe" data-id="${escapeHtml(s.id)}" ${state.actionBusy || isMeetingGenerating(s.id) ? "disabled" : ""}>${svgIcon("notes")}${actionLabel}</button>`
              : ""
          }
        </div>
        ${
          isActiveTruncated
            ? `<div class="banner info"><div><strong>内容过长已截断显示</strong><div class="muted-note">${
                state.detailTab === "transcript" &&
                !s.hasTranscript &&
                detail.transcribedChunkIds.length > 1
                  ? "完整分片文件已保存在本机目录"
                  : "完整文件已保存在本机"
              }：<code>${escapeHtml(activeDiskPath)}</code></div></div></div>`
            : ""
        }
      </div>
      <div class="markdown-body">
        ${
          !activeText.trim() && s.chunkCount > 0 && !isRecordingThis && s.status !== "empty"
            ? `<div class="notes-empty-cta">
                 <strong>${state.detailTab === "notes" ? "尚未生成会议纪要" : "尚未生成逐字稿"}</strong>
                 <div class="muted-note">本场会议已录制 ${formatDuration(s.totalDurationSec)}（${s.chunkCount} 个音频切片${s.transcribedChunkCount > 0 ? ` · 已转写 ${s.transcribedChunkCount} 片` : ""}）。</div>
                 <button class="btn btn-primary btn-sm" data-action="transcribe" data-id="${escapeHtml(s.id)}" ${state.actionBusy || isMeetingGenerating(s.id) ? "disabled" : ""}>
                   ${svgIcon("notes")}${actionLabel}
                 </button>
               </div>`
            : renderMarkdown(activeText)
        }
      </div>
    `;
    }

    return `
      <div class="history-detail-view" data-history-detail-view="true">
        <div class="detail-nav-bar">
          <button type="button" class="btn btn-sm btn-ghost detail-back-btn" data-action="close-detail">
            ${svgIcon("back")}返回会议列表
          </button>
        </div>
        <div class="history-detail">${detailHtml}</div>
      </div>
    `;
  }

  const items = state.searchHits
    ? state.searchHits.map((hit) => ({
        id: hit.id,
        title: hit.title,
        mode: hit.mode ?? state.recentMeetings.find((x) => x.id === hit.id)?.mode ?? "mic",
        createdAt: hit.createdAt,
        totalDurationSec: hit.totalDurationSec,
        snippet: hit.snippet,
        hasNotes: hit.hasNotes,
        hasTranscript: hit.hasTranscript,
      }))
    : state.recentMeetings.map((m) => ({
        id: m.id,
        title: m.title,
        mode: m.mode,
        createdAt: m.createdAt,
        totalDurationSec: m.totalDurationSec,
        snippet: `${m.chunkCount} 片 · ${isMeetingGenerating(m.id) ? "独立会话生成中" : m.status === "partial" || m.failedChunkCount > 0 ? "部分完成" : m.hasNotes ? "已有纪要" : m.transcribedChunkCount > 0 ? `已转写 ${m.transcribedChunkCount}/${m.chunkCount}` : "未转写"}`,
        hasNotes: m.hasNotes,
        hasTranscript: m.hasTranscript,
      }));

  const listHtml =
    items.length === 0
      ? `<div class="empty-state">${state.searchQuery.trim() ? "没有匹配的会议记录" : "暂无历史会议"}</div>`
      : items
          .map((item) => {
            const active = state.selectedMeetingId === item.id;
            return `
              <div class="meeting-item clickable ${active ? "selected" : ""}" data-action="select-meeting" data-id="${escapeHtml(item.id)}">
                <div class="meeting-item-top">
                  <div class="meeting-title">${escapeHtml(item.title)}</div>
                  <div class="item-actions">
                    <span class="badge">${item.mode === "dual" ? "双轨" : "仅麦"}</span>
                    <span class="badge ${item.hasNotes ? "done" : ""}">${item.hasNotes ? "纪要" : item.hasTranscript ? "逐字稿" : "待处理"}</span>
                    <span class="meeting-chevron">${svgIcon("chevron")}</span>
                  </div>
                </div>
                <div class="meeting-meta">
                  <span>${escapeHtml(formatDate(item.createdAt))}</span>
                  <span>${formatDuration(item.totalDurationSec)}</span>
                </div>
                <div class="muted-note">${escapeHtml(item.snippet)}</div>
              </div>
            `;
          })
          .join("");

  return `
    <div class="history-list-view" data-history-list-view="true">
      <div class="retention-bar" data-retention-bar="true">
        <div class="retention-bar-left">
          <strong>原音频留存策略</strong>
          <span class="muted-note">仅清理原始 .m4a，保留纪要、逐字稿与发言统计；未转写音频绝不自动删除。</span>
        </div>
        <select id="retention-policy-select" class="select-input" ${state.actionBusy ? "disabled" : ""}>
          <option value="manual" ${state.audioRetentionPolicy === "manual" ? "selected" : ""}>永久保留（手动清理）</option>
          <option value="after_notes" ${state.audioRetentionPolicy === "after_notes" ? "selected" : ""}>生成纪要后自动清理</option>
          <option value="days_7" ${state.audioRetentionPolicy === "days_7" ? "selected" : ""}>保留 7 天（仅清理已完成纪要）</option>
        </select>
      </div>
      <div class="history-sidebar">
        <input id="search-input" class="text-input" type="search" placeholder="搜索标题、纪要或逐字稿..." value="${escapeHtml(state.searchQuery)}" />
        <div class="meeting-list">${listHtml}</div>
      </div>
    </div>
  `;
}

function render() {
  const root = document.getElementById("root");
  if (!root) return;

  const activeEl = document.activeElement as HTMLInputElement | null;
  const activeId = activeEl?.id ?? null;
  const selectionStart = activeEl?.selectionStart ?? null;
  const selectionEnd = activeEl?.selectionEnd ?? null;

  const recState = state.snapshot?.state ?? "idle";
  const pillClass =
    recState === "recording"
      ? "recording"
      : recState === "finalizing" || recState === "starting"
        ? "finalizing"
        : state.daemonRunning
          ? "ready"
          : "";
  const pillLabel =
    recState === "recording"
      ? `录制中 ${formatDuration(state.snapshot?.elapsedSec ?? 0)}`
      : recState === "finalizing"
        ? "封包中"
        : recState === "starting"
          ? "启动中"
          : state.daemonRunning
            ? "就绪"
            : "待连接";

  root.innerHTML = `
    <div class="app-shell">
      <header class="top-bar">
        <div class="tab-group">
          <button class="tab-btn ${state.tab === "live" ? "active" : ""}" data-action="switch-live">录制</button>
          <button class="tab-btn ${state.tab === "history" ? "active" : ""}" data-action="switch-history">历史 (${state.recentMeetings.length})</button>
        </div>
        <span class="status-pill ${pillClass}"><span class="status-dot"></span>${escapeHtml(pillLabel)}</span>
      </header>
      <main class="content-area">
        ${
          state.bannerError
            ? `<div class="banner error"><span>${escapeHtml(state.bannerError)}</span><button class="btn btn-sm" data-action="dismiss-error">关闭</button></div>`
            : ""
        }
        ${
          state.copiedPromptBox
            ? `<div class="banner info">
                 <div style="flex:1;min-width:0;">
                   <strong>已复制「生成会议纪要」指令</strong>
                   <div class="muted-note">${escapeHtml(state.copiedPromptBox.reason ?? `会议 ID：${state.copiedPromptBox.meetingId}`)}</div>
                   <textarea class="prompt-preview" readonly rows="2">${escapeHtml(state.copiedPromptBox.prompt)}</textarea>
                 </div>
                 <div class="item-actions">
                   <button class="btn btn-primary btn-sm" data-action="copy-prompt-box">再次复制</button>
                   ${
                     state.copiedPromptBox.allowCurrentChatFallback
                       ? `<button class="btn btn-sm" data-action="transcribe-current" data-id="${escapeHtml(state.copiedPromptBox.meetingId)}" ${state.actionBusy ? "disabled" : ""}>改在当前对话生成</button>`
                       : ""
                   }
                   <button class="btn btn-sm btn-ghost" data-action="dismiss-prompt-box">关闭</button>
                 </div>
               </div>`
            : ""
        }
        ${state.tab === "live" ? renderLiveTab() : renderHistoryTab()}
      </main>
    </div>
    ${state.toastText ? `<div class="toast">${escapeHtml(state.toastText)}</div>` : ""}
  `;

  if (activeId) {
    const restored = document.getElementById(activeId) as HTMLInputElement | null;
    if (restored) {
      restored.focus();
      if (selectionStart !== null && selectionEnd !== null && typeof restored.setSelectionRange === "function") {
        try {
          restored.setSelectionRange(selectionStart, selectionEnd);
        } catch {
          // type=search or unsupported selection
        }
      }
    }
  }
}

document.addEventListener("input", (event) => {
  const target = event.target as HTMLInputElement | null;
  if (!target) return;
  if (target.id === "draft-title-input") {
    state.draftTitle = target.value;
  } else if (target.id === "search-input") {
    void handleSearch(target.value);
  } else if (target.id === "rename-input") {
    state.renameDraft = target.value;
  }
});

document.addEventListener("change", (event) => {
  const target = event.target as HTMLSelectElement | null;
  if (!target || target.id !== "retention-policy-select") return;
  const val = target.value;
  if (val === "manual" || val === "after_notes" || val === "days_7") {
    void handleChangeRetentionPolicy(val);
  }
});

document.addEventListener("click", (event) => {
  const rawEl = event.target as HTMLElement | null;
  const mdLink = rawEl?.closest("a.md-link[href]") as HTMLAnchorElement | null;
  if (mdLink) {
    event.preventDefault();
    const href = mdLink.getAttribute("href") ?? "";
    if (href) {
      if (state.hasOpenLinksCap && /^https?:/i.test(href)) {
        void app
          .openLink({ url: href })
          .then((res) => {
            if (res?.isError) {
              void copyMarkdownText(href);
            }
          })
          .catch(() => {
            void copyMarkdownText(href);
          });
      } else {
        void copyMarkdownText(href);
      }
    }
    return;
  }
  const clickedBtn = rawEl?.closest("button") as HTMLButtonElement | null;
  if (clickedBtn?.disabled) return;
  const target = rawEl?.closest("[data-action]") as HTMLElement | null;
  if (!target) return;
  if (clickedBtn && target !== clickedBtn) return;
  const action = target.dataset.action;
  const id = target.dataset.id;

  switch (action) {
    case "switch-live":
      state.tab = "live";
      render();
      void pollLiveOnce({ autoLaunch: !state.daemonRunning, forceRender: true });
      break;
    case "switch-history":
      state.tab = "history";
      state.historyDetailOpen = false;
      render();
      break;
    case "dismiss-error":
      state.bannerError = null;
      render();
      break;
    case "dismiss-cta":
      state.justStoppedMeetingId = null;
      render();
      break;
    case "dismiss-probe-msg":
      state.lastAudioProbeMessage = null;
      render();
      break;
    case "dismiss-prompt-box":
      state.copiedPromptBox = null;
      render();
      break;
    case "copy-prompt-box":
      if (state.copiedPromptBox) {
        void copyMarkdownText(state.copiedPromptBox.prompt);
      }
      break;
    case "retry-poll":
      state.bannerError = null;
      void pollLiveOnce({ autoLaunch: true, forceRender: true });
      break;
    case "select-mode": {
      const recSt = state.snapshot?.state ?? "idle";
      if (recSt !== "recording" && recSt !== "finalizing" && recSt !== "starting") {
        state.selectedMode = target.dataset.mode === "mic" ? "mic" : "dual";
        state.lastAudioProbeMessage = null;
        render();
      }
      break;
    }
    case "request-mic":
      void handleRequestPermission("mic", false);
      break;
    case "open-mic-settings":
      void handleRequestPermission("mic", true);
      break;
    case "recheck-mic":
      void handleRequestPermission("mic", false, true);
      break;
    case "request-sysaudio":
      void handleRequestPermission("systemAudio", false);
      break;
    case "open-sysaudio-settings":
      void handleRequestPermission("systemAudio", true);
      break;
    case "recheck-sysaudio":
      void handleRequestPermission("systemAudio", false, true);
      break;
    case "start":
      void handleStartRecording();
      break;
    case "stop":
      void handleStopRecording();
      break;
    case "transcribe": {
      const detailSummary = state.selectedDetail?.summary;
      const m =
        state.recentMeetings.find((x) => x.id === id) ??
        (detailSummary?.id === id ? detailSummary : undefined);
      if (m) void handleSendToAgent(m, { target: "new" });
      break;
    }
    case "transcribe-current": {
      const detailSummary = state.selectedDetail?.summary;
      const m =
        state.recentMeetings.find((x) => x.id === id) ??
        (detailSummary?.id === id ? detailSummary : undefined);
      if (m) void handleSendToAgent(m, { target: "current" });
      break;
    }
    case "open-detail":
      if (id) openMeetingDetail(id);
      break;
    case "select-meeting":
      if (id) openMeetingDetail(id);
      break;
    case "close-detail":
      closeMeetingDetail();
      break;
    case "detail-tab":
      state.detailTab = target.dataset.tab === "transcript" ? "transcript" : "notes";
      render();
      break;
    case "copy-active":
      if (state.selectedDetail) {
        const text =
          state.detailTab === "notes"
            ? state.selectedDetail.notes
            : state.selectedDetail.transcript;
        void copyMarkdownText(text);
      }
      break;
    case "ask-cleanup":
      state.confirmCleanupId = id ?? null;
      render();
      break;
    case "cancel-cleanup":
      state.confirmCleanupId = null;
      render();
      break;
    case "confirm-cleanup":
      if (id) void handleCleanupAudio(id);
      break;
    case "ask-delete":
      state.confirmDeleteId = id ?? null;
      render();
      break;
    case "cancel-delete":
      state.confirmDeleteId = null;
      render();
      break;
    case "confirm-delete":
      if (id) void handleDeleteMeeting(id);
      break;
    case "start-rename":
      state.renamingId = id ?? null;
      state.renameDraft = target.dataset.title ?? "";
      render();
      break;
    case "cancel-rename":
      state.renamingId = null;
      render();
      break;
    case "save-rename":
      if (id) void handleSaveRename(id);
      break;
    default:
      break;
  }
});

function applyHostContext(ctx: ReturnType<App["getHostContext"]>) {
  if (!ctx) return;
  if (ctx.theme) applyDocumentTheme(ctx.theme);
  if (ctx.styles?.variables) applyHostStyleVariables(ctx.styles.variables);
}

app.ontoolinput = (params) => {
  const args = (params.arguments ?? {}) as { view?: string; meetingId?: string };
  if (args.meetingId) {
    openMeetingDetail(args.meetingId);
    return;
  }
  if (args.view === "history") {
    state.tab = "history";
    state.historyDetailOpen = false;
  }
  if (args.view === "live") state.tab = "live";
  render();
};

app.ontoolresult = (result) => {
  const data = (result.structuredContent ?? {}) as {
    requestedView?: string | null;
    requestedMeetingId?: string | null;
    snapshot?: RecorderSnapshot | null;
    recentMeetings?: MeetingSummary[];
  };
  if (data.snapshot) state.snapshot = data.snapshot;
  if (Array.isArray(data.recentMeetings)) state.recentMeetings = data.recentMeetings;
  if (data.requestedMeetingId) {
    openMeetingDetail(data.requestedMeetingId);
    return;
  }
  if (data.requestedView === "history") {
    state.tab = "history";
    state.historyDetailOpen = false;
  }
  if (data.requestedView === "live") state.tab = "live";
  render();
};

app.onhostcontextchanged = (ctx) => {
  applyHostContext(ctx);
};

async function boot() {
  render();
  try {
    await app.connect();
    const caps = app.getHostCapabilities() as Record<string, unknown> | undefined;
    state.hasMessageCap = Boolean(caps?.message);
    state.hasOpenLinksCap = Boolean(caps?.openLinks);
    applyHostContext(app.getHostContext());
  } catch (err) {
    state.bannerError = `连接宿主视图失败：${err instanceof Error ? err.message : String(err)}`;
  }
  await pollLiveOnce({ autoLaunch: state.tab === "live", forceRender: true });

  if (pollTimer === null) {
    pollTimer = window.setInterval(() => {
      void pollLiveOnce({ autoLaunch: false });
    }, 1200);
  }
}

void boot();
