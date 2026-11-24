import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { StringDecoder } from "node:string_decoder";
import type { ChunkRecord, ChunkTimeline, GapRecord, MeetingManifest } from "./daemon.js";
import {
  extractTopLevelRawTokens,
  parseRawNonNegativeUint64,
  patchTopLevelJsonFields,
  patchTopLevelJsonRawFields,
  rawJsonTokensEqual,
  removeTopLevelJsonField,
  scanTopLevelJsonObject,
} from "./jsonPatch.js";
import { safeOpenat } from "./native.js";

const MEETING_ID_RE = /^[a-zA-Z0-9_-]{4,64}$/;
const CHUNK_ID_RE = /^[a-zA-Z0-9_-]{3,32}$/;
const CHUNK_REL_PATH_RE = /^chunks\/([a-zA-Z0-9_-][a-zA-Z0-9._-]*\.m4a)$/;
const TIMELINE_REL_PATH_RE = /^timelines\/([a-zA-Z0-9_-][a-zA-Z0-9._-]*\.json)$/;
const CLEANUP_STAGING_DIR_RE =
  /^\.cleanup-staging\.[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CLEANUP_STAGED_CHUNK_FILE_RE =
  /^\d+_[0-9a-f]{8}__chunks__[a-zA-Z0-9_-][a-zA-Z0-9._-]*\.m4a$/;

function isOwnedStagedFileName(name: string): "chunks" | null {
  if (CLEANUP_STAGED_CHUNK_FILE_RE.test(name)) return "chunks";
  return null;
}
const LEASE_FILE_NAME = ".transcribing.lock.json";
const LEASE_BACKUP_FILE_RE =
  /^\.\.transcribing\.lock\.json\.[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.tmp$/i;
const MANIFEST_BACKUP_FILE_RE =
  /^\.manifest\.json\.[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.tmp$/i;
const MANIFEST_SNAP_FILE_RE =
  /^\.manifest-snap\.[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.tmp$/i;
const SAVE_TX_FILE_NAME = ".save-tx.json";
const CLEANUP_REVERT_MARKER = ".revert-audio-cleaned";
const EXPIRED_LEASE_JSON = JSON.stringify({ updatedAt: 0, expiresAt: 0 });
const DEFAULT_LEASE_TTL_MS = 5 * 60_000;
const MAX_SAFE_TEXT_READ_BYTES = 20 * 1024 * 1024;
const MAX_SAFE_MANIFEST_BYTES = 16 * 1024 * 1024;
const SAVE_TX_MAX_BYTES = MAX_SAFE_MANIFEST_BYTES + 256 * 1024;
const MAX_VIEW_FIELD_RAW_BYTES = 180_000;
const MAX_VIEW_FIELD_JSON_BYTES = 240_000;
const DEFAULT_MODEL_ENVELOPE_BUDGET_BYTES = 850_000;
const COMPACT_TEXT_THRESHOLD_BYTES = 32_768;
const MAX_MEETING_TITLE_CHARS = 500;
const REVISION_HASH_MAX_BYTES = 256 * 1024;

function openSafeReadFlags(): number {
  return safeOpenat.O_RDONLY | safeOpenat.O_NOFOLLOW | safeOpenat.O_NONBLOCK | safeOpenat.O_CLOEXEC;
}

function openSafeDirFlags(): number {
  return safeOpenat.O_RDONLY | safeOpenat.O_NOFOLLOW | safeOpenat.O_DIRECTORY | safeOpenat.O_CLOEXEC;
}

const OPEN_SAFE_WRITE_FLAGS =
  fs.constants.O_WRONLY |
  fs.constants.O_CREAT |
  fs.constants.O_EXCL |
  (fs.constants.O_NOFOLLOW ?? 0);

export interface MeetingSummary {
  id: string;
  title: string;
  mode: string;
  appTarget: string;
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
  hasCleanableAudio: boolean;
}

export interface MeetingChunkInfo extends ChunkRecord {
  absoluteAudioPath: string;
  fileExists: boolean;
  absoluteMicPath?: string;
  micFileExists?: boolean;
  absoluteRemotePath?: string;
  remoteFileExists?: boolean;
  absoluteTimelinePath?: string;
  timelineFileExists?: boolean;
  transcribed: boolean;
}

export interface SpeakerStats {
  meSec: number;
  remoteSec: number;
  bothSec: number;
  timelineChunkCount: number;
}

export interface GetMeetingForModelOptions {
  chunkOffset?: number;
  chunkLimit?: number;
  onlyMissing?: boolean;
  maxEnvelopeBytes?: number;
  acquireLeaseIfNeeded?: boolean;
  beforeLease?: (payload: MeetingForModel) => void;
}

export type MeetingModelManifest = Omit<MeetingManifest, "hostTimeOriginNs">;

export interface MeetingForModel {
  manifest: MeetingModelManifest;
  meetingDir: string;
  chunks: MeetingChunkInfo[];
  totalChunks: number;
  chunkOffset: number;
  chunkLimit: number;
  hasMoreChunks: boolean;
  nextChunkOffset: number | null;
  chunksTruncated: boolean;
  transcribedChunkIds: string[];
  missingChunkIds: string[];
  hasFullTranscript: boolean;
  hasNotes: boolean;
  transcriptPath: string;
  notesPath: string;
  partialTranscriptPaths: Record<string, string>;
}

export interface MeetingViewManifest {
  schemaVersion: number;
  id: string;
  title: string;
  mode: string;
  appTarget: string;
  status: string;
  createdAt: string;
  endedAt?: string;
  totalDurationSec: number;
  gaps: GapRecord[];
  audioCleaned: boolean;
  failedChunkCount?: number;
  lastError?: string;
}

export interface MeetingViewDetail {
  revision: string;
  summary: MeetingSummary;
  manifest: MeetingViewManifest;
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

export interface SearchHit {
  id: string;
  title: string;
  mode: string;
  createdAt: string;
  totalDurationSec: number;
  hasNotes: boolean;
  hasTranscript: boolean;
  matchedIn: ("title" | "notes" | "transcript")[];
  snippet: string;
}

export type AudioRetentionPolicy = "manual" | "after_notes" | "days_7";
export type UiLanguage = "en" | "zh";

export interface PluginSettings {
  audioRetentionPolicy: AudioRetentionPolicy;
  uiLanguage: UiLanguage;
}

export interface NotesJobRecord {
  meetingId: string;
  startedAt: number;
  updatedAt: number;
  prevHasNotes: boolean;
  prevNotesRevision?: string;
  clientJobId?: string;
}

const VALID_RETENTION_POLICIES = new Set<AudioRetentionPolicy>([
  "manual",
  "after_notes",
  "days_7",
]);
const VALID_UI_LANGUAGES = new Set<UiLanguage>(["en", "zh"]);
const DEFAULT_PLUGIN_SETTINGS: PluginSettings = {
  audioRetentionPolicy: "manual",
  uiLanguage: "en",
};
const SEVEN_DAYS_MS = 7 * 24 * 60 * 60 * 1000;
const NOTES_JOB_IDLE_TTL_MS = 15 * 60_000;

export interface SaveResultPreview {
  savedPath: string;
  meetingId: string;
  kind: string;
  chunkId?: string;
}

type SafeFdReadResult =
  | { kind: "missing" }
  | { kind: "invalid"; reason: string }
  | { kind: "too_large"; size: number }
  | {
      kind: "ok";
      content: string;
      totalBytes: number;
      truncated: boolean;
      stat: fs.Stats;
      bigintStat?: fs.BigIntStats;
      rawBytes?: Buffer;
    };

type SafeOpenResult =
  | { kind: "missing" }
  | { kind: "invalid"; reason: string }
  | { kind: "ok"; fd: number; stat: fs.Stats };

type MeetingSubdir = "chunks" | "timelines" | "transcripts" | ".commits";

type CasResult =
  | { kind: "swapped" }
  | { kind: "conflict"; preservedLatest: boolean; backupPath?: string; detail: string };

function lstatIfExists(targetPath: string): fs.Stats | null {
  try {
    return fs.lstatSync(targetPath);
  } catch (err) {
    if ((err as NodeJS.ErrnoException | undefined)?.code === "ENOENT") {
      return null;
    }
    throw err;
  }
}

function lstatIfExistsBigInt(targetPath: string): fs.BigIntStats | null {
  try {
    return fs.lstatSync(targetPath, { bigint: true });
  } catch (err) {
    if ((err as NodeJS.ErrnoException | undefined)?.code === "ENOENT") {
      return null;
    }
    throw err;
  }
}

function sameBigIntFileIdentity(a: fs.BigIntStats, b: fs.BigIntStats): boolean {
  return (
    a.dev === b.dev &&
    a.ino === b.ino &&
    a.size === b.size &&
    a.mtimeNs === b.mtimeNs &&
    a.birthtimeNs === b.birthtimeNs
  );
}

function parseLeaseExpiresAt(raw: string | null | undefined): number | null {
  if (typeof raw !== "string") return null;
  try {
    const parsed = JSON.parse(raw) as unknown;
    if (
      isPlainRecord(parsed) &&
      typeof parsed.expiresAt === "number" &&
      Number.isFinite(parsed.expiresAt)
    ) {
      return parsed.expiresAt;
    }
  } catch {
    // ignore invalid JSON
  }
  return null;
}

function isLeaseExpiredOrInvalid(raw: string | null | undefined): boolean {
  const exp = parseLeaseExpiresAt(raw);
  return exp === null || exp <= Date.now();
}

function sha256Hex(bytes: Buffer): string {
  return crypto.createHash("sha256").update(bytes).digest("hex");
}

type FileIdentityRecord = {
  dev: string;
  ino: string;
  size: string;
  mtimeNs: string;
  birthtimeNs: string;
  sha256: string;
};

type SavedFileIdentity =
  | { exists: false }
  | {
      exists: true;
      dev: string;
      ino: string;
      size: string;
      mtimeNs: string;
      birthtimeNs: string;
      sha256?: string;
    };

type PendingManifestMergeRecord = {
  backupRelPath: string;
  snapshotRelPath: string;
  nextTitle: string;
  fallbackPrevTitle: string;
  attemptedTitleToken: string | null;
};

function buildFileIdentityFromHash(stat: fs.BigIntStats, sha256: string): FileIdentityRecord {
  return {
    dev: stat.dev.toString(),
    ino: stat.ino.toString(),
    size: stat.size.toString(),
    mtimeNs: stat.mtimeNs.toString(),
    birthtimeNs: stat.birthtimeNs.toString(),
    sha256: sha256.toLowerCase(),
  };
}

function buildFileIdentity(stat: fs.BigIntStats, rawBytes: Buffer): FileIdentityRecord {
  return buildFileIdentityFromHash(stat, sha256Hex(rawBytes));
}

function isValidFileIdentityRecord(raw: unknown): raw is FileIdentityRecord {
  if (!isPlainRecord(raw)) return false;
  return (
    typeof raw.dev === "string" &&
    /^-?\d+$/.test(raw.dev) &&
    typeof raw.ino === "string" &&
    /^-?\d+$/.test(raw.ino) &&
    typeof raw.size === "string" &&
    /^-?\d+$/.test(raw.size) &&
    typeof raw.mtimeNs === "string" &&
    /^-?\d+$/.test(raw.mtimeNs) &&
    typeof raw.birthtimeNs === "string" &&
    /^-?\d+$/.test(raw.birthtimeNs) &&
    typeof raw.sha256 === "string" &&
    /^[0-9a-f]{64}$/i.test(raw.sha256)
  );
}

function matchesFileIdentityHash(
  stat: fs.BigIntStats,
  sha256: string,
  expected: FileIdentityRecord,
): boolean {
  return (
    stat.dev.toString() === expected.dev &&
    stat.ino.toString() === expected.ino &&
    stat.size.toString() === expected.size &&
    stat.mtimeNs.toString() === expected.mtimeNs &&
    stat.birthtimeNs.toString() === expected.birthtimeNs &&
    sha256.toLowerCase() === expected.sha256.toLowerCase()
  );
}

function matchesFileIdentity(
  stat: fs.BigIntStats,
  rawBytes: Buffer,
  expected: FileIdentityRecord,
): boolean {
  return matchesFileIdentityHash(stat, sha256Hex(rawBytes), expected);
}

function matchesSavedFileIdentityHash(
  stat: fs.BigIntStats,
  sha256: string,
  expected: Extract<SavedFileIdentity, { exists: true }>,
): boolean {
  return (
    stat.dev.toString() === expected.dev &&
    stat.ino.toString() === expected.ino &&
    stat.size.toString() === expected.size &&
    stat.mtimeNs.toString() === expected.mtimeNs &&
    stat.birthtimeNs.toString() === expected.birthtimeNs &&
    (expected.sha256 === undefined || sha256.toLowerCase() === expected.sha256.toLowerCase())
  );
}

function isValidSavedFileIdentity(raw: unknown): raw is SavedFileIdentity {
  if (!isPlainRecord(raw)) return false;
  if (raw.exists === false) return true;
  if (raw.exists !== true) return false;
  if (
    typeof raw.dev !== "string" ||
    !/^-?\d+$/.test(raw.dev) ||
    typeof raw.ino !== "string" ||
    !/^-?\d+$/.test(raw.ino) ||
    typeof raw.size !== "string" ||
    !/^-?\d+$/.test(raw.size) ||
    typeof raw.mtimeNs !== "string" ||
    !/^-?\d+$/.test(raw.mtimeNs) ||
    typeof raw.birthtimeNs !== "string" ||
    !/^-?\d+$/.test(raw.birthtimeNs)
  ) {
    return false;
  }
  if (raw.sha256 !== undefined) {
    return typeof raw.sha256 === "string" && /^[0-9a-f]{64}$/i.test(raw.sha256);
  }
  return true;
}

function isValidPendingMergeRecord(raw: unknown): raw is PendingManifestMergeRecord {
  if (!isPlainRecord(raw)) return false;
  return (
    typeof raw.backupRelPath === "string" &&
    MANIFEST_BACKUP_FILE_RE.test(raw.backupRelPath) &&
    typeof raw.snapshotRelPath === "string" &&
    MANIFEST_SNAP_FILE_RE.test(raw.snapshotRelPath) &&
    typeof raw.nextTitle === "string" &&
    typeof raw.fallbackPrevTitle === "string" &&
    (raw.attemptedTitleToken === null || typeof raw.attemptedTitleToken === "string")
  );
}

function readRegularFileBytesIfExists(
  targetPath: string,
  maxBytes = MAX_SAFE_MANIFEST_BYTES,
): Buffer | null {
  const cap = Math.max(0, Math.floor(maxBytes));
  let fd = -1;
  try {
    fd = fs.openSync(targetPath, openSafeReadFlags());
    const st = fs.fstatSync(fd);
    if (!st.isFile() || st.size > cap) {
      return null;
    }
    const limitToRead = cap + 1;
    const parts: Buffer[] = [];
    let totalRead = 0;
    const bufSize = Math.min(65_536, Math.max(1024, limitToRead));
    while (totalRead < limitToRead) {
      const wanted = Math.min(bufSize, limitToRead - totalRead);
      const buf = Buffer.allocUnsafe(wanted);
      let n = 0;
      try {
        n = fs.readSync(fd, buf, 0, wanted, null);
      } catch (err) {
        const code = (err as NodeJS.ErrnoException | undefined)?.code;
        if (code === "EAGAIN" || code === "EINTR") continue;
        throw err;
      }
      if (n === 0) break;
      parts.push(n === wanted ? buf : buf.subarray(0, n));
      totalRead += n;
    }
    if (totalRead > cap) {
      return null;
    }
    return parts.length === 0
      ? Buffer.alloc(0)
      : parts.length === 1
        ? parts[0]
        : Buffer.concat(parts, totalRead);
  } catch (err) {
    const code = (err as NodeJS.ErrnoException | undefined)?.code;
    if (
      code === "ENOENT" ||
      code === "ELOOP" ||
      code === "ENXIO" ||
      code === "EISDIR" ||
      code === "ENOTDIR"
    ) {
      return null;
    }
    throw err;
  } finally {
    if (fd >= 0) {
      try {
        fs.closeSync(fd);
      } catch {
        // ignore
      }
    }
  }
}

function isPlainRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function isSafeComponent(name: string): boolean {
  return (
    name.length > 0 &&
    name !== "." &&
    name !== ".." &&
    !name.includes("/") &&
    !name.includes("\0")
  );
}

function isWellFormedUnicode(text: string): boolean {
  const maybeFn = (text as unknown as { isWellFormed?: () => boolean }).isWellFormed;
  if (typeof maybeFn === "function") {
    return maybeFn.call(text);
  }
  return !/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?:^|[^\uD800-\uDBFF])[\uDC00-\uDFFF]/.test(text);
}

function trimToJsonByteBudget(
  text: string,
  maxJsonBytes: number,
): { text: string; trimmed: boolean } {
  if (Buffer.byteLength(JSON.stringify(text), "utf8") <= maxJsonBytes) {
    return { text, trimmed: false };
  }
  let lo = 0;
  let hi = text.length;
  while (lo < hi) {
    let mid = Math.ceil((lo + hi) / 2);
    if (mid > 0 && mid < text.length) {
      const code = text.charCodeAt(mid - 1);
      if (code >= 0xd800 && code <= 0xdbff) {
        mid -= 1;
      }
    }
    if (mid <= lo) {
      break;
    }
    const candidate = text.slice(0, mid);
    if (Buffer.byteLength(JSON.stringify(candidate), "utf8") <= maxJsonBytes) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return { text: text.slice(0, lo), trimmed: true };
}

function buildStagedFileName(
  index: number,
  sub: "chunks",
  origBaseName: string,
): string {
  const prefix = `${index}_${crypto.randomUUID().slice(0, 8)}__${sub}__`;
  const maxTotalLen = 250;
  if (prefix.length + origBaseName.length <= maxTotalLen) {
    return `${prefix}${origBaseName}`;
  }
  const ext = ".m4a";
  const maxStemLen = Math.max(1, maxTotalLen - prefix.length - ext.length);
  const stem = origBaseName.slice(0, origBaseName.length - ext.length).slice(0, maxStemLen);
  return `${prefix}${stem}${ext}`;
}

function measureModelEnvelopeBytes(payload: Record<string, unknown>): number {
  const compact = JSON.stringify(payload);
  const text =
    Buffer.byteLength(compact, "utf8") <= COMPACT_TEXT_THRESHOLD_BYTES
      ? JSON.stringify(payload, null, 2)
      : compact;
  return Buffer.byteLength(
    JSON.stringify({
      content: [{ type: "text", text }],
      structuredContent: payload,
    }),
    "utf8",
  );
}

export class MeetingStore {
  readonly meetingsDir: string;
  private readonly dataDir: string;
  private readonly enforceDataDirNotSymlink: boolean;

  constructor(meetingsDir: string, dataDir?: string) {
    this.meetingsDir = path.resolve(meetingsDir);
    this.dataDir = dataDir ? path.resolve(dataDir) : path.dirname(this.meetingsDir);
    this.enforceDataDirNotSymlink =
      Boolean(dataDir) || path.basename(this.meetingsDir) === "meetings";
  }

  private cancelledNotesJobsPath(): string {
    return path.join(this.dataDir, "notes-jobs-cancelled.json");
  }

  private readCancelledNotesJobsUnlocked(now: number): {
    entries: Record<string, number>;
    changed: boolean;
  } {
    const filePath = this.cancelledNotesJobsPath();
    const lst = lstatIfExists(filePath);
    const out: Record<string, number> = Object.create(null) as Record<string, number>;
    if (!lst || lst.isSymbolicLink() || !lst.isFile()) {
      return { entries: out, changed: false };
    }
    let changed = false;
    try {
      const parsed = JSON.parse(fs.readFileSync(filePath, "utf8")) as unknown;
      if (!isPlainRecord(parsed)) {
        return { entries: out, changed: true };
      }
      for (const [key, val] of Object.entries(parsed)) {
        if (
          typeof key === "string" &&
          key.length > 0 &&
          key.length <= 256 &&
          typeof val === "number" &&
          Number.isFinite(val) &&
          val > now
        ) {
          out[key] = val;
        } else {
          changed = true;
        }
      }
      return { entries: out, changed };
    } catch {
      return { entries: out, changed: true };
    }
  }

  private writeCancelledNotesJobsUnlocked(entries: Record<string, number>): void {
    const targetPath = this.cancelledNotesJobsPath();
    const targetLst = lstatIfExists(targetPath);
    if (targetLst && (targetLst.isSymbolicLink() || !targetLst.isFile())) {
      throw new Error(`拒绝写入符号链接或非普通取消记录文件: ${targetPath}`);
    }
    const keys = Object.keys(entries);
    if (keys.length === 0) {
      if (targetLst) {
        fs.unlinkSync(targetPath);
      }
      return;
    }
    const tmpPath = path.join(this.dataDir, `.notes-jobs-cancelled.json.${crypto.randomUUID()}.tmp`);
    try {
      fs.writeFileSync(tmpPath, `${JSON.stringify(entries, null, 2)}\n`, {
        encoding: "utf8",
        mode: 0o600,
      });
      fs.renameSync(tmpPath, targetPath);
    } catch (err) {
      try {
        fs.unlinkSync(tmpPath);
      } catch {
        // ignore cleanup error
      }
      throw err;
    }
  }

  private settingsPath(): string {
    return path.join(this.dataDir, "settings.json");
  }

  private assertDataDirSafe(createIfMissing: boolean): void {
    const existing = lstatIfExists(this.dataDir);
    if (existing) {
      if (existing.isSymbolicLink() || !existing.isDirectory()) {
        throw new Error(`数据目录非法（不允许符号链接）: ${this.dataDir}`);
      }
      return;
    }
    if (!createIfMissing) {
      return;
    }
    fs.mkdirSync(this.dataDir, { recursive: true });
    const after = fs.lstatSync(this.dataDir);
    if (after.isSymbolicLink() || !after.isDirectory()) {
      throw new Error(`数据目录非法（不允许符号链接）: ${this.dataDir}`);
    }
  }

  getSettings(): PluginSettings {
    if (this.enforceDataDirNotSymlink) {
      const dataLst = lstatIfExists(this.dataDir);
      if (!dataLst || dataLst.isSymbolicLink() || !dataLst.isDirectory()) {
        return { ...DEFAULT_PLUGIN_SETTINGS };
      }
    }
    const filePath = this.settingsPath();
    const lst = lstatIfExists(filePath);
    if (!lst || lst.isSymbolicLink() || !lst.isFile()) {
      return { ...DEFAULT_PLUGIN_SETTINGS };
    }
    try {
      const parsed = JSON.parse(fs.readFileSync(filePath, "utf8")) as {
        audioRetentionPolicy?: unknown;
        uiLanguage?: unknown;
      };
      const audioRetentionPolicy =
        parsed &&
        typeof parsed.audioRetentionPolicy === "string" &&
        VALID_RETENTION_POLICIES.has(parsed.audioRetentionPolicy as AudioRetentionPolicy)
          ? (parsed.audioRetentionPolicy as AudioRetentionPolicy)
          : DEFAULT_PLUGIN_SETTINGS.audioRetentionPolicy;
      const uiLanguage =
        parsed &&
        typeof parsed.uiLanguage === "string" &&
        VALID_UI_LANGUAGES.has(parsed.uiLanguage as UiLanguage)
          ? (parsed.uiLanguage as UiLanguage)
          : DEFAULT_PLUGIN_SETTINGS.uiLanguage;
      return { audioRetentionPolicy, uiLanguage };
    } catch {
      // Corrupt or unreadable settings safely fall back to defaults.
    }
    return { ...DEFAULT_PLUGIN_SETTINGS };
  }

  setSettings(next: Partial<PluginSettings>): PluginSettings {
    const current = this.getSettings();
    const audioRetentionPolicy =
      next.audioRetentionPolicy !== undefined ? next.audioRetentionPolicy : current.audioRetentionPolicy;
    const uiLanguage = next.uiLanguage !== undefined ? next.uiLanguage : current.uiLanguage;
    if (!VALID_RETENTION_POLICIES.has(audioRetentionPolicy)) {
      throw new Error(`非法原音频留存策略: ${String(audioRetentionPolicy)}`);
    }
    if (!VALID_UI_LANGUAGES.has(uiLanguage)) {
      throw new Error(`Invalid UI language: ${String(uiLanguage)}`);
    }
    this.assertDataDirSafe(true);
    const targetPath = this.settingsPath();
    const targetLst = lstatIfExists(targetPath);
    if (targetLst && (targetLst.isSymbolicLink() || !targetLst.isFile())) {
      throw new Error(`拒绝写入符号链接或非普通设置文件: ${targetPath}`);
    }
    const saved: PluginSettings = { audioRetentionPolicy, uiLanguage };
    const tmpPath = path.join(this.dataDir, `.settings.json.${crypto.randomUUID()}.tmp`);
    try {
      fs.writeFileSync(tmpPath, `${JSON.stringify(saved, null, 2)}\n`, {
        encoding: "utf8",
        mode: 0o600,
      });
      fs.renameSync(tmpPath, targetPath);
    } catch (err) {
      try {
        fs.unlinkSync(tmpPath);
      } catch {
        // ignore cleanup error
      }
      throw err;
    }
    return saved;
  }

  private notesJobsPath(): string {
    return path.join(this.dataDir, "notes-jobs.json");
  }

  private withNotesJobsLock<T>(fn: () => T): T {
    this.assertDataDirSafe(true);
    let dirFd = -1;
    let locked = false;
    try {
      dirFd = safeOpenat.openDir(this.dataDir, openSafeDirFlags());
      safeOpenat.flock(dirFd, safeOpenat.LOCK_EX);
      locked = true;
      return fn();
    } finally {
      if (locked && dirFd >= 0) {
        try {
          safeOpenat.flock(dirFd, safeOpenat.LOCK_UN);
        } catch {
          // ignore
        }
      }
      if (dirFd >= 0) {
        try {
          fs.closeSync(dirFd);
        } catch {
          // ignore
        }
      }
    }
  }

  private readNotesJobsUnlocked(): Record<string, NotesJobRecord> {
    const filePath = this.notesJobsPath();
    const lst = lstatIfExists(filePath);
    if (!lst || lst.isSymbolicLink() || !lst.isFile()) {
      return {};
    }
    try {
      const parsed = JSON.parse(fs.readFileSync(filePath, "utf8")) as unknown;
      if (!isPlainRecord(parsed)) return {};
      const out: Record<string, NotesJobRecord> = {};
      for (const [id, raw] of Object.entries(parsed)) {
        if (!MEETING_ID_RE.test(id) || !isPlainRecord(raw)) continue;
        if (
          typeof raw.startedAt === "number" &&
          Number.isFinite(raw.startedAt) &&
          typeof raw.updatedAt === "number" &&
          Number.isFinite(raw.updatedAt) &&
          typeof raw.prevHasNotes === "boolean"
        ) {
          out[id] = {
            meetingId: id,
            startedAt: raw.startedAt,
            updatedAt: raw.updatedAt,
            prevHasNotes: raw.prevHasNotes,
            ...(typeof raw.prevNotesRevision === "string"
              ? { prevNotesRevision: raw.prevNotesRevision }
              : {}),
            ...(typeof raw.clientJobId === "string" &&
            raw.clientJobId.length > 0 &&
            raw.clientJobId.length <= 128
              ? { clientJobId: raw.clientJobId }
              : {}),
          };
        }
      }
      return out;
    } catch {
      return {};
    }
  }

  private writeNotesJobsUnlocked(jobs: Record<string, NotesJobRecord>): void {
    const targetPath = this.notesJobsPath();
    const targetLst = lstatIfExists(targetPath);
    if (targetLst && (targetLst.isSymbolicLink() || !targetLst.isFile())) {
      throw new Error(`拒绝写入符号链接或非普通任务文件: ${targetPath}`);
    }
    const keys = Object.keys(jobs);
    if (keys.length === 0) {
      if (targetLst) {
        fs.unlinkSync(targetPath);
      }
      return;
    }
    const tmpPath = path.join(this.dataDir, `.notes-jobs.json.${crypto.randomUUID()}.tmp`);
    try {
      fs.writeFileSync(tmpPath, `${JSON.stringify(jobs, null, 2)}\n`, {
        encoding: "utf8",
        mode: 0o600,
      });
      fs.renameSync(tmpPath, targetPath);
    } catch (err) {
      try {
        fs.unlinkSync(tmpPath);
      } catch {
        // ignore cleanup error
      }
      throw err;
    }
  }

  private safeGetSummary(meetingId: string): MeetingSummary | null {
    if (!MEETING_ID_RE.test(meetingId)) return null;
    try {
      const dir = this.resolveMeetingDir(meetingId);
      const manifest = this.readManifest(meetingId);
      return this.toSummary(meetingId, dir, manifest);
    } catch {
      return null;
    }
  }

  private safeIsTranscribing(meetingId: string): boolean {
    try {
      return this.isTranscribing(meetingId);
    } catch {
      return false;
    }
  }

  private reconcileNotesJobsUnlocked(
    jobs: Record<string, NotesJobRecord>,
    now: number,
  ): { active: Record<string, NotesJobRecord>; changed: boolean } {
    const active: Record<string, NotesJobRecord> = {};
    let changed = false;
    for (const [id, job] of Object.entries(jobs)) {
      const summary = this.safeGetSummary(id);
      if (
        !summary ||
        summary.status === "recording" ||
        summary.status === "finalizing" ||
        summary.status === "empty" ||
        summary.chunkCount === 0
      ) {
        changed = true;
        continue;
      }
      const completed =
        summary.hasNotes &&
        (!job.prevHasNotes ||
          (job.prevNotesRevision !== undefined &&
            summary.notesRevision !== job.prevNotesRevision));
      const expired =
        now - job.updatedAt >= NOTES_JOB_IDLE_TTL_MS && !this.safeIsTranscribing(id);
      if (completed || expired) {
        changed = true;
        continue;
      }
      active[id] = job;
    }
    return { active, changed };
  }

  claimNotesJob(
    meetingId: string,
    clientJobId?: string,
  ): { claimed: boolean; job?: NotesJobRecord; cancelled?: boolean } {
    if (!MEETING_ID_RE.test(meetingId)) {
      throw new Error(`非法 meetingId: ${meetingId}`);
    }
    const summary = this.safeGetSummary(meetingId);
    if (!summary) {
      throw new Error(`未找到会议记录: ${meetingId}`);
    }
    if (
      summary.status === "recording" ||
      summary.status === "finalizing" ||
      summary.status === "empty" ||
      summary.chunkCount === 0
    ) {
      throw new Error(`会议 ${meetingId} 当前状态 (${summary.status}) 不可生成纪要`);
    }

    const sanitizedClientJobId =
      typeof clientJobId === "string" && clientJobId.length > 0 && clientJobId.length <= 128
        ? clientJobId
        : undefined;

    return this.withNotesJobsLock(() => {
      const now = Date.now();
      const { entries: cancelled, changed: cancelledChanged } =
        this.readCancelledNotesJobsUnlocked(now);
      if (sanitizedClientJobId !== undefined) {
        const tombstoneKey = `${meetingId}:${sanitizedClientJobId}`;
        if (
          Object.prototype.hasOwnProperty.call(cancelled, tombstoneKey) &&
          cancelled[tombstoneKey] > now
        ) {
          if (cancelledChanged) {
            this.writeCancelledNotesJobsUnlocked(cancelled);
          }
          return { claimed: false, cancelled: true };
        }
      }
      if (cancelledChanged) {
        this.writeCancelledNotesJobsUnlocked(cancelled);
      }
      const raw = this.readNotesJobsUnlocked();
      const { active, changed } = this.reconcileNotesJobsUnlocked(raw, now);
      if (active[meetingId]) {
        if (changed) {
          this.writeNotesJobsUnlocked(active);
        }
        return { claimed: false, job: active[meetingId] };
      }
      const nextJob: NotesJobRecord = {
        meetingId,
        startedAt: now,
        updatedAt: now,
        prevHasNotes: summary.hasNotes,
        ...(summary.notesRevision !== undefined
          ? { prevNotesRevision: summary.notesRevision }
          : {}),
        ...(sanitizedClientJobId !== undefined ? { clientJobId: sanitizedClientJobId } : {}),
      };
      active[meetingId] = nextJob;
      this.writeNotesJobsUnlocked(active);
      return { claimed: true, job: nextJob };
    });
  }

  releaseNotesJob(meetingId: string, clientJobId?: string): boolean {
    if (!MEETING_ID_RE.test(meetingId)) return false;
    if (this.enforceDataDirNotSymlink) {
      const dataLst = lstatIfExists(this.dataDir);
      if (!dataLst || dataLst.isSymbolicLink() || !dataLst.isDirectory()) return false;
    }
    const sanitizedClientJobId =
      typeof clientJobId === "string" && clientJobId.length > 0 && clientJobId.length <= 128
        ? clientJobId
        : undefined;
    if (sanitizedClientJobId === undefined && !lstatIfExists(this.notesJobsPath())) {
      return false;
    }
    return this.withNotesJobsLock(() => {
      const now = Date.now();
      if (sanitizedClientJobId !== undefined) {
        const { entries } = this.readCancelledNotesJobsUnlocked(now);
        entries[`${meetingId}:${sanitizedClientJobId}`] = now + 5 * 60_000;
        this.writeCancelledNotesJobsUnlocked(entries);
      }
      if (!lstatIfExists(this.notesJobsPath())) return false;
      const raw = this.readNotesJobsUnlocked();
      const existing = raw[meetingId];
      if (!existing) return false;
      if (clientJobId !== undefined && existing.clientJobId !== clientJobId) {
        return false;
      }
      delete raw[meetingId];
      this.writeNotesJobsUnlocked(raw);
      return true;
    });
  }

  touchNotesJob(meetingId: string): void {
    if (!MEETING_ID_RE.test(meetingId)) return;
    if (this.enforceDataDirNotSymlink) {
      const dataLst = lstatIfExists(this.dataDir);
      if (!dataLst || dataLst.isSymbolicLink() || !dataLst.isDirectory()) return;
    }
    if (!lstatIfExists(this.notesJobsPath())) return;
    this.withNotesJobsLock(() => {
      const raw = this.readNotesJobsUnlocked();
      const existing = raw[meetingId];
      if (!existing) return;
      raw[meetingId] = { ...existing, updatedAt: Date.now() };
      this.writeNotesJobsUnlocked(raw);
    });
  }

  listActiveNotesJobIds(): string[] {
    if (this.enforceDataDirNotSymlink) {
      const dataLst = lstatIfExists(this.dataDir);
      if (!dataLst || dataLst.isSymbolicLink() || !dataLst.isDirectory()) return [];
    }
    if (!lstatIfExists(this.notesJobsPath())) return [];
    return this.withNotesJobsLock(() => {
      const now = Date.now();
      const raw = this.readNotesJobsUnlocked();
      const { active, changed } = this.reconcileNotesJobsUnlocked(raw, now);
      if (changed) {
        this.writeNotesJobsUnlocked(active);
      }
      return Object.keys(active);
    });
  }

  getSummariesByIds(meetingIds: string[]): Record<string, MeetingSummary> {
    const out: Record<string, MeetingSummary> = {};
    const uniqueIds = Array.from(
      new Set(
        meetingIds
          .map((id) => (typeof id === "string" ? id.trim() : ""))
          .filter((id) => MEETING_ID_RE.test(id)),
      ),
    ).slice(0, 50);
    for (const id of uniqueIds) {
      const summary = this.safeGetSummary(id);
      if (summary) {
        out[id] = summary;
      }
    }
    return out;
  }

  private isEligibleForAutoCleanup(
    s: MeetingSummary,
    policy: AudioRetentionPolicy,
    nowMs: number,
    skipMeetingId?: string | null,
    includeAfterNotes?: boolean,
  ): boolean {
    if (skipMeetingId && s.id === skipMeetingId) return false;
    if (!s.hasCleanableAudio) return false;
    if (s.status !== "recorded") return false;
    if (s.failedChunkCount > 0 || s.chunkCount === 0) return false;
    if (!s.hasNotes || !s.hasTranscript || s.missingChunkCount > 0) return false;
    if (this.isTranscribing(s.id)) return false;
    if (policy === "days_7") {
      const refMs = Date.parse(s.endedAt ?? s.createdAt);
      if (!Number.isFinite(refMs) || nowMs - refMs < SEVEN_DAYS_MS) {
        return false;
      }
      return true;
    }
    if (policy === "after_notes") {
      return includeAfterNotes === true;
    }
    return false;
  }

  tryAutoCleanupAfterNotes(meetingId: string): { cleaned: boolean; freedBytes: number } {
    const settings = this.getSettings();
    if (settings.audioRetentionPolicy !== "after_notes") {
      return { cleaned: false, freedBytes: 0 };
    }
    try {
      const view = this.getMeetingView(meetingId);
      if (
        !this.isEligibleForAutoCleanup(
          view.summary,
          "after_notes",
          Date.now(),
          null,
          true,
        )
      ) {
        return { cleaned: false, freedBytes: 0 };
      }
      const res = this.cleanupAudio(meetingId);
      return { cleaned: true, freedBytes: res.freedBytes };
    } catch {
      return { cleaned: false, freedBytes: 0 };
    }
  }

  applyRetentionPolicy(options?: {
    nowMs?: number;
    skipMeetingId?: string | null;
    includeAfterNotes?: boolean;
  }): { cleanedMeetingIds: string[]; freedBytes: number } {
    const settings = this.getSettings();
    if (
      settings.audioRetentionPolicy === "manual" ||
      (settings.audioRetentionPolicy === "after_notes" && options?.includeAfterNotes !== true)
    ) {
      return { cleanedMeetingIds: [], freedBytes: 0 };
    }
    const nowMs = options?.nowMs ?? Date.now();
    const summaries = this.loadAllMeetingSummaries();
    const cleanedMeetingIds: string[] = [];
    let freedBytes = 0;
    for (const s of summaries) {
      if (
        !this.isEligibleForAutoCleanup(
          s,
          settings.audioRetentionPolicy,
          nowMs,
          options?.skipMeetingId,
          options?.includeAfterNotes,
        )
      ) {
        continue;
      }
      try {
        const res = this.cleanupAudio(s.id);
        cleanedMeetingIds.push(s.id);
        freedBytes += res.freedBytes;
      } catch {
        // Best-effort sweep: skip meetings locked by another active operation.
      }
    }
    return { cleanedMeetingIds, freedBytes };
  }

  ensureRoot(): string {
    if (this.enforceDataDirNotSymlink) {
      this.assertDataDirSafe(false);
    }
    const existingMeetings = lstatIfExists(this.meetingsDir);
    if (existingMeetings && (existingMeetings.isSymbolicLink() || !existingMeetings.isDirectory())) {
      throw new Error(`会议数据根目录非法（不允许符号链接）: ${this.meetingsDir}`);
    }
    fs.mkdirSync(this.meetingsDir, { recursive: true });
    if (this.enforceDataDirNotSymlink) {
      const dataAfter = fs.lstatSync(this.dataDir);
      if (dataAfter.isSymbolicLink() || !dataAfter.isDirectory()) {
        throw new Error(`数据目录非法（不允许符号链接）: ${this.dataDir}`);
      }
    }
    const st = fs.lstatSync(this.meetingsDir);
    if (st.isSymbolicLink() || !st.isDirectory()) {
      throw new Error(`会议数据根目录非法（不允许符号链接）: ${this.meetingsDir}`);
    }
    return fs.realpathSync(this.meetingsDir);
  }

  resolveMeetingDir(meetingId: string): string {
    if (!MEETING_ID_RE.test(meetingId)) {
      throw new Error(`非法 meetingId: ${meetingId}`);
    }
    const realRoot = this.ensureRoot();
    const candidate = path.resolve(this.meetingsDir, meetingId);
    const expectedPrefix = realRoot.endsWith(path.sep) ? realRoot : `${realRoot}${path.sep}`;

    const lst = lstatIfExists(candidate);
    if (lst) {
      if (lst.isSymbolicLink() || !lst.isDirectory()) {
        throw new Error(`拒绝访问符号链接或非目录会议路径: ${meetingId}`);
      }
      const realCandidate = fs.realpathSync(candidate);
      if (!realCandidate.startsWith(expectedPrefix) || realCandidate !== path.join(realRoot, meetingId)) {
        throw new Error(`路径越界: ${meetingId}`);
      }
      return realCandidate;
    }

    const baseCheck = path.resolve(realRoot, meetingId);
    if (!baseCheck.startsWith(expectedPrefix)) {
      throw new Error(`路径越界: ${meetingId}`);
    }
    return baseCheck;
  }

  validateChunkId(chunkId: string): string {
    if (!CHUNK_ID_RE.test(chunkId)) {
      throw new Error(`非法 chunkId: ${chunkId}`);
    }
    return chunkId;
  }

  private openRootFd(): number {
    const realRoot = this.ensureRoot();
    const lstBefore = fs.lstatSync(this.meetingsDir);
    if (lstBefore.isSymbolicLink() || !lstBefore.isDirectory()) {
      throw new Error(`会议数据根目录非法（不允许符号链接）: ${this.meetingsDir}`);
    }
    const fd = safeOpenat.openDir(realRoot, openSafeDirFlags());
    try {
      const fdStat = fs.fstatSync(fd);
      const lstAfter = fs.lstatSync(this.meetingsDir);
      if (
        !fdStat.isDirectory() ||
        lstAfter.isSymbolicLink() ||
        !lstAfter.isDirectory() ||
        fdStat.dev !== lstBefore.dev ||
        fdStat.ino !== lstBefore.ino ||
        fdStat.dev !== lstAfter.dev ||
        fdStat.ino !== lstAfter.ino
      ) {
        throw new Error(`会议数据根目录状态不一致: ${this.meetingsDir}`);
      }
      return fd;
    } catch (err) {
      try {
        fs.closeSync(fd);
      } catch {
        // ignore
      }
      throw err;
    }
  }

  private withMeetingWriteLock<T>(meetingId: string, fn: () => T): T {
    if (!MEETING_ID_RE.test(meetingId)) {
      throw new Error(`非法 meetingId: ${meetingId}`);
    }
    let rootFd = -1;
    let meetingFd = -1;
    let locked = false;
    try {
      rootFd = this.openRootFd();
      try {
        meetingFd = safeOpenat.openat(rootFd, meetingId, openSafeDirFlags());
      } catch (err) {
        const code = (err as NodeJS.ErrnoException | undefined)?.code;
        if (code === "ENOENT") {
          throw new Error(`未找到会议记录: ${meetingId}`);
        }
        if (code === "ELOOP" || code === "ENOTDIR" || code === "ENXIO") {
          throw new Error(`拒绝访问符号链接或非目录会议路径: ${meetingId}`);
        }
        throw err;
      } finally {
        try {
          fs.closeSync(rootFd);
        } catch {
          // ignore
        }
        rootFd = -1;
      }

      safeOpenat.flock(meetingFd, safeOpenat.LOCK_EX);
      locked = true;
      const lockedStat = fs.fstatSync(meetingFd, { bigint: true });
      const currentPathStat = lstatIfExistsBigInt(path.join(this.meetingsDir, meetingId));
      if (!currentPathStat) {
        throw new Error(`未找到会议记录: ${meetingId}`);
      }
      if (
        currentPathStat.isSymbolicLink() ||
        !currentPathStat.isDirectory() ||
        currentPathStat.dev !== lockedStat.dev ||
        currentPathStat.ino !== lockedStat.ino ||
        lockedStat.nlink === 0n
      ) {
        throw new Error(`会议目录在加锁过程中已被移除或变更: ${meetingId}`);
      }
      return fn();
    } finally {
      if (locked && meetingFd >= 0) {
        try {
          safeOpenat.flock(meetingFd, safeOpenat.LOCK_UN);
        } catch {
          // ignore
        }
      }
      if (meetingFd >= 0) {
        try {
          fs.closeSync(meetingFd);
        } catch {
          // ignore
        }
      }
      if (rootFd >= 0) {
        try {
          fs.closeSync(rootFd);
        } catch {
          // ignore
        }
      }
    }
  }

  private openMeetingFileByComponents(
    meetingId: string,
    subdir: MeetingSubdir | null,
    fileName: string,
  ): SafeOpenResult {
    if (!MEETING_ID_RE.test(meetingId)) {
      return { kind: "invalid", reason: "invalid_meeting_id" };
    }
    if (!isSafeComponent(fileName)) {
      return { kind: "invalid", reason: "invalid_filename" };
    }

    let rootFd = -1;
    let meetingFd = -1;
    let subFd = -1;
    let fileFd = -1;
    try {
      try {
        rootFd = this.openRootFd();
      } catch (err) {
        const code = (err as NodeJS.ErrnoException | undefined)?.code;
        if (code === "ENOENT") return { kind: "missing" };
        if (code === "ELOOP" || code === "ENOTDIR" || code === "ENXIO") {
          return { kind: "invalid", reason: code };
        }
        throw err;
      }

      try {
        meetingFd = safeOpenat.openat(rootFd, meetingId, openSafeDirFlags());
      } catch (err) {
        const code = (err as NodeJS.ErrnoException | undefined)?.code;
        if (code === "ENOENT") return { kind: "missing" };
        if (code === "ELOOP" || code === "ENOTDIR" || code === "ENXIO") {
          return { kind: "invalid", reason: code };
        }
        throw err;
      }

      let parentFd = meetingFd;
      if (subdir !== null) {
        try {
          subFd = safeOpenat.openat(meetingFd, subdir, openSafeDirFlags());
        } catch (err) {
          const code = (err as NodeJS.ErrnoException | undefined)?.code;
          if (code === "ENOENT") return { kind: "missing" };
          if (code === "ELOOP" || code === "ENOTDIR" || code === "ENXIO") {
            return { kind: "invalid", reason: code };
          }
          throw err;
        }
        parentFd = subFd;
      }

      try {
        fileFd = safeOpenat.openat(parentFd, fileName, openSafeReadFlags());
      } catch (err) {
        const code = (err as NodeJS.ErrnoException | undefined)?.code;
        if (code === "ENOENT") return { kind: "missing" };
        if (code === "ELOOP" || code === "ENXIO" || code === "ENOTDIR" || code === "EISDIR") {
          return { kind: "invalid", reason: code };
        }
        throw err;
      }

      const st = fs.fstatSync(fileFd);
      if (!st.isFile()) {
        fs.closeSync(fileFd);
        fileFd = -1;
        return { kind: "invalid", reason: "not_regular_file" };
      }

      const verifiedFd = fileFd;
      fileFd = -1;
      return { kind: "ok", fd: verifiedFd, stat: st };
    } finally {
      if (fileFd >= 0) {
        try {
          fs.closeSync(fileFd);
        } catch {
          // ignore
        }
      }
      if (subFd >= 0) {
        try {
          fs.closeSync(subFd);
        } catch {
          // ignore
        }
      }
      if (meetingFd >= 0) {
        try {
          fs.closeSync(meetingFd);
        } catch {
          // ignore
        }
      }
      if (rootFd >= 0) {
        try {
          fs.closeSync(rootFd);
        } catch {
          // ignore
        }
      }
    }
  }

  private readMeetingFileByFd(
    meetingId: string,
    subdir: MeetingSubdir | null,
    fileName: string,
    options: { maxReadBytes: number; allowTruncate: boolean },
  ): SafeFdReadResult {
    const opened = this.openMeetingFileByComponents(meetingId, subdir, fileName);
    if (opened.kind !== "ok") {
      return opened;
    }

    const { fd, stat: st } = opened;
    try {
      const cap = Math.max(0, Math.floor(options.maxReadBytes));
      if (!options.allowTruncate && st.size > cap) {
        return { kind: "too_large", size: st.size };
      }

      const limitToRead = options.allowTruncate ? cap : cap + 1;
      const parts: Buffer[] = [];
      let totalRead = 0;
      const bufSize = Math.min(65_536, Math.max(1024, limitToRead));

      while (totalRead < limitToRead) {
        const wanted = Math.min(bufSize, limitToRead - totalRead);
        const buf = Buffer.allocUnsafe(wanted);
        let n = 0;
        try {
          n = fs.readSync(fd, buf, 0, wanted, null);
        } catch (err) {
          const code = (err as NodeJS.ErrnoException | undefined)?.code;
          if (code === "EAGAIN" || code === "EINTR") continue;
          throw err;
        }
        if (n === 0) break;
        parts.push(n === wanted ? buf : buf.subarray(0, n));
        totalRead += n;
      }

      const combined =
        parts.length === 0
          ? Buffer.alloc(0)
          : parts.length === 1
            ? parts[0]
            : Buffer.concat(parts, totalRead);

      if (!options.allowTruncate) {
        if (totalRead > cap) {
          return { kind: "too_large", size: Math.max(st.size, totalRead) };
        }
        const bigintStat = fs.fstatSync(fd, { bigint: true });
        return {
          kind: "ok",
          content: combined.toString("utf8"),
          totalBytes: st.size,
          truncated: false,
          stat: st,
          bigintStat,
          rawBytes: combined,
        };
      }

      let truncated = st.size > totalRead;
      if (!truncated && totalRead === cap) {
        const probe = Buffer.allocUnsafe(1);
        const extra = fs.readSync(fd, probe, 0, 1, null);
        if (extra > 0) {
          truncated = true;
        }
      }

      const content = truncated
        ? new StringDecoder("utf8").write(combined)
        : combined.toString("utf8");

      return {
        kind: "ok",
        content,
        totalBytes: st.size,
        truncated,
        stat: st,
      };
    } finally {
      fs.closeSync(fd);
    }
  }

  private statMeetingFileByFd(
    meetingId: string,
    subdir: MeetingSubdir | null,
    fileName: string,
  ): fs.Stats | null {
    try {
      const opened = this.openMeetingFileByComponents(meetingId, subdir, fileName);
      if (opened.kind !== "ok") {
        return null;
      }
      try {
        return opened.stat;
      } finally {
        fs.closeSync(opened.fd);
      }
    } catch {
      return null;
    }
  }

  private readFileIdentityByFdUnlocked(
    meetingId: string,
    subdir: MeetingSubdir | null,
    fileName: string,
  ):
    | { kind: "missing" }
    | { kind: "invalid" }
    | { kind: "ok"; bigintStat: fs.BigIntStats; sha256: string } {
    const opened = this.openMeetingFileByComponents(meetingId, subdir, fileName);
    if (opened.kind === "missing") {
      return { kind: "missing" };
    }
    if (opened.kind !== "ok") {
      return { kind: "invalid" };
    }
    const { fd } = opened;
    try {
      const bigintStat = fs.fstatSync(fd, { bigint: true });
      const hash = crypto.createHash("sha256");
      const buf = Buffer.allocUnsafe(256 * 1024);
      while (true) {
        let n = 0;
        try {
          n = fs.readSync(fd, buf, 0, buf.length, null);
        } catch (err) {
          const code = (err as NodeJS.ErrnoException | undefined)?.code;
          if (code === "EAGAIN" || code === "EINTR") continue;
          throw err;
        }
        if (n === 0) break;
        hash.update(n === buf.length ? buf : buf.subarray(0, n));
      }
      return { kind: "ok", bigintStat, sha256: hash.digest("hex") };
    } finally {
      fs.closeSync(fd);
    }
  }

  private assertSafeSubdir(meetingDir: string, subdirName: MeetingSubdir): string | null {
    const meetingId = path.basename(meetingDir);
    let rootFd = -1;
    let meetingFd = -1;
    let subFd = -1;
    try {
      rootFd = this.openRootFd();
      meetingFd = safeOpenat.openat(rootFd, meetingId, openSafeDirFlags());
      try {
        subFd = safeOpenat.openat(meetingFd, subdirName, openSafeDirFlags());
      } catch (err) {
        const code = (err as NodeJS.ErrnoException | undefined)?.code;
        if (code === "ENOENT") {
          return null;
        }
        if (code === "ELOOP" || code === "ENOTDIR" || code === "ENXIO") {
          throw new Error(`拒绝访问符号链接或非目录子路径: ${subdirName}`);
        }
        throw err;
      }
      const subDir = path.join(meetingDir, subdirName);
      const realMeeting = fs.realpathSync(meetingDir);
      const realSub = fs.realpathSync(subDir);
      if (realSub !== path.join(realMeeting, subdirName)) {
        throw new Error(`子目录越界: ${subdirName}`);
      }
      return realSub;
    } finally {
      if (subFd >= 0) {
        try {
          fs.closeSync(subFd);
        } catch {
          // ignore
        }
      }
      if (meetingFd >= 0) {
        try {
          fs.closeSync(meetingFd);
        } catch {
          // ignore
        }
      }
      if (rootFd >= 0) {
        try {
          fs.closeSync(rootFd);
        } catch {
          // ignore
        }
      }
    }
  }

  private assertSafeLeaseTarget(dir: string): void {
    fs.accessSync(dir, fs.constants.W_OK | fs.constants.X_OK);
    const lockPath = path.join(dir, LEASE_FILE_NAME);
    const lst = lstatIfExists(lockPath);
    if (lst && (lst.isSymbolicLink() || !lst.isFile())) {
      throw new Error(`拒绝写入异常转写锁目标: ${LEASE_FILE_NAME}`);
    }
  }

  private resolveSafeMeetingSubpath(
    meetingId: string,
    meetingDir: string,
    subdirName: "chunks" | "timelines",
    relPath: string,
    pattern: RegExp,
  ): { absPath: string; fileName: string; exists: boolean; stat?: fs.Stats } {
    if (typeof relPath !== "string" || relPath.includes("..")) {
      throw new Error(`非法切片子路径: ${String(relPath)}`);
    }
    const match = pattern.exec(relPath);
    if (!match) {
      throw new Error(`非法切片子路径: ${String(relPath)}`);
    }
    const fileName = match[1];
    const safeSub = this.assertSafeSubdir(meetingDir, subdirName);
    const realMeeting = fs.realpathSync(meetingDir);
    const absPath = path.resolve(realMeeting, relPath);
    const subPrefix = path.join(realMeeting, subdirName) + path.sep;
    if (!absPath.startsWith(subPrefix)) {
      throw new Error(`切片路径越界: ${relPath}`);
    }
    if (!safeSub) {
      return { absPath, fileName, exists: false };
    }

    const opened = this.openMeetingFileByComponents(meetingId, subdirName, fileName);
    if (opened.kind === "missing") {
      return { absPath, fileName, exists: false };
    }
    if (opened.kind === "invalid") {
      throw new Error(`拒绝访问符号链接、管道或非普通文件: ${relPath}`);
    }
    try {
      return { absPath, fileName, exists: true, stat: opened.stat };
    } finally {
      fs.closeSync(opened.fd);
    }
  }

  private writeStagingTempFileAtName(dir: string, fileName: string, content: string): string {
    const tmp = path.join(dir, fileName);
    const data = Buffer.from(content, "utf8");
    let fd: number | null = null;
    try {
      fd = fs.openSync(tmp, OPEN_SAFE_WRITE_FLAGS, 0o644);
      let written = 0;
      while (written < data.byteLength) {
        written += fs.writeSync(fd, data, written, data.byteLength - written);
      }
      fs.closeSync(fd);
      fd = null;
      return tmp;
    } catch (err) {
      if (fd !== null) {
        try {
          fs.closeSync(fd);
        } catch {
          // ignore
        }
      }
      try {
        fs.unlinkSync(tmp);
      } catch {
        // ignore
      }
      throw err;
    }
  }

  private writeStagingTempFile(dir: string, targetBaseName: string, content: string): string {
    return this.writeStagingTempFileAtName(
      dir,
      `.${targetBaseName}.${crypto.randomUUID()}.tmp`,
      content,
    );
  }

  private atomicWriteFile(filePath: string, content: string): void {
    const existing = lstatIfExists(filePath);
    if (existing && (existing.isSymbolicLink() || !existing.isFile())) {
      throw new Error(`拒绝覆盖符号链接、管道或非普通文件: ${path.basename(filePath)}`);
    }

    const dir = path.dirname(filePath);
    fs.mkdirSync(dir, { recursive: true });
    const dirStat = fs.lstatSync(dir);
    if (dirStat.isSymbolicLink() || !dirStat.isDirectory()) {
      throw new Error(`拒绝写入非真实目录: ${dir}`);
    }

    const tmp = this.writeStagingTempFile(dir, path.basename(filePath), content);
    try {
      const preRename = lstatIfExists(filePath);
      if (preRename && (preRename.isSymbolicLink() || !preRename.isFile())) {
        throw new Error(`拒绝覆盖符号链接、管道或非普通文件: ${path.basename(filePath)}`);
      }
      fs.renameSync(tmp, filePath);
    } catch (err) {
      try {
        fs.unlinkSync(tmp);
      } catch {
        // ignore
      }
      throw err;
    }
  }

  private atomicCompareAndSwapFile(
    filePath: string,
    content: string,
    expectedStat: fs.BigIntStats,
    expectedRawBytes: Buffer,
    options?: {
      onBeforeCreateTmp?: (tmpBaseName: string) => void;
      onBeforeSwap?: (
        myStat: fs.BigIntStats,
        contentBytes: Buffer,
        tmpPath: string,
        expectedStat: fs.BigIntStats,
        expectedRawBytes: Buffer,
      ) => void;
      onSwapExecuted?: () => void;
      onSwapReverted?: () => void;
      onPreserveBackup?: (backupPath: string, detail: string) => void;
    },
  ): CasResult {
    const contentBytes = Buffer.from(content, "utf8");
    const targetMaxBytes = Math.max(MAX_SAFE_MANIFEST_BYTES, contentBytes.byteLength);
    const preTarget = lstatIfExistsBigInt(filePath);
    if (
      !preTarget ||
      preTarget.isSymbolicLink() ||
      !preTarget.isFile() ||
      !sameBigIntFileIdentity(preTarget, expectedStat)
    ) {
      return { kind: "conflict", preservedLatest: true, detail: "changed_before_swap" };
    }

    const dir = path.dirname(filePath);
    const dirStat = fs.lstatSync(dir);
    if (dirStat.isSymbolicLink() || !dirStat.isDirectory()) {
      throw new Error(`拒绝写入非真实目录: ${dir}`);
    }

    const tmpBaseName = `.${path.basename(filePath)}.${crypto.randomUUID()}.tmp`;
    options?.onBeforeCreateTmp?.(tmpBaseName);
    const tmp = this.writeStagingTempFileAtName(dir, tmpBaseName, content);
    let swappedOutExternal = false;
    let preserveTmp = false;
    let notifiedBackup = false;
    const notifyPreservedBackup = (detail: string) => {
      preserveTmp = true;
      if (!notifiedBackup) {
        notifiedBackup = true;
        options?.onPreserveBackup?.(tmp, detail);
      }
    };

    try {
      const myStat = fs.lstatSync(tmp, { bigint: true });
      options?.onBeforeSwap?.(myStat, contentBytes, tmp, expectedStat, expectedRawBytes);
      safeOpenat.renamex_swap(tmp, filePath);
      swappedOutExternal = true;
      options?.onSwapExecuted?.();

      let oldStat: fs.BigIntStats;
      let matchesExpected = false;
      try {
        oldStat = fs.lstatSync(tmp, { bigint: true });
        const statMatches =
          !oldStat.isSymbolicLink() &&
          oldStat.isFile() &&
          sameBigIntFileIdentity(oldStat, expectedStat);
        if (statMatches && fs.readFileSync(tmp).equals(expectedRawBytes)) {
          matchesExpected = true;
        }
      } catch (verifyErr) {
        let undoVerified = false;
        const preUndoTmpStat = (() => {
          try {
            return lstatIfExistsBigInt(tmp);
          } catch {
            return null;
          }
        })();
        const curT = lstatIfExistsBigInt(filePath);
        const curB =
          curT && !curT.isSymbolicLink() && curT.isFile()
            ? readRegularFileBytesIfExists(filePath, targetMaxBytes)
            : null;
        if (
          curT &&
          !curT.isSymbolicLink() &&
          curT.isFile() &&
          sameBigIntFileIdentity(curT, myStat) &&
          curB !== null &&
          curB.equals(contentBytes)
        ) {
          try {
            safeOpenat.renamex_swap(tmp, filePath);
            const postUndoStat = lstatIfExistsBigInt(tmp);
            const postUndoBytes =
              postUndoStat && !postUndoStat.isSymbolicLink() && postUndoStat.isFile()
                ? readRegularFileBytesIfExists(tmp, targetMaxBytes)
                : null;
            if (
              postUndoStat &&
              !postUndoStat.isSymbolicLink() &&
              postUndoStat.isFile() &&
              sameBigIntFileIdentity(postUndoStat, myStat) &&
              postUndoBytes !== null &&
              postUndoBytes.equals(contentBytes)
            ) {
              swappedOutExternal = false;
              undoVerified = true;
            } else {
              // Newer Version C raced in right before Undo Swap 2; Swap 3 restores C back onto filePath.
              const afterUndoTarget = lstatIfExistsBigInt(filePath);
              if (
                afterUndoTarget &&
                (!preUndoTmpStat || sameBigIntFileIdentity(afterUndoTarget, preUndoTmpStat))
              ) {
                try {
                  safeOpenat.renamex_swap(tmp, filePath);
                } catch {
                  // Preserve C in tmp below.
                }
              }
            }
          } catch {
            // Leave undoVerified = false so preserveTmp keeps tmp intact.
          }
        }
        if (undoVerified) {
          options?.onSwapReverted?.();
          throw verifyErr;
        }
        notifyPreservedBackup("verify_error_preserved_in_backup");
        throw verifyErr;
      }

      if (matchesExpected) {
        swappedOutExternal = false;
        return { kind: "swapped" };
      }

      // Conflict: `tmp` now holds external Version B (`oldStat`). Best-effort capture B's bytes; never abort Swap 2 on transient read EIO.
      let versionBBytes: Buffer | null = null;
      if (!oldStat.isSymbolicLink() && oldStat.isFile()) {
        try {
          versionBBytes = readRegularFileBytesIfExists(tmp, targetMaxBytes);
        } catch {
          versionBBytes = null;
        }
      }

      // Check if Version C replaced `filePath` OR overwrote `myIno` in-place after Swap 1.
      const curTarget = lstatIfExistsBigInt(filePath);
      if (!curTarget) {
        preserveTmp = true;
        return {
          kind: "conflict",
          preservedLatest: false,
          backupPath: tmp,
          detail: "target_deleted_during_swap",
        };
      }
      const curBytes =
        !curTarget.isSymbolicLink() && curTarget.isFile()
          ? readRegularFileBytesIfExists(filePath, targetMaxBytes)
          : null;
      const targetUnchangedFromMine =
        !curTarget.isSymbolicLink() &&
        curTarget.isFile() &&
        sameBigIntFileIdentity(curTarget, myStat) &&
        curBytes !== null &&
        curBytes.equals(contentBytes);
      if (!targetUnchangedFromMine) {
        // Newer external Version C sits on `filePath`, while `tmp` still holds displaced Version B: preserve B in backup!
        preserveTmp = true;
        return {
          kind: "conflict",
          preservedLatest: false,
          backupPath: tmp,
          detail: "superseded_by_newer_external_write",
        };
      }

      try {
        safeOpenat.renamex_swap(tmp, filePath);
      } catch (swapBackErr) {
        preserveTmp = true;
        const msg = swapBackErr instanceof Error ? swapBackErr.message : String(swapBackErr);
        return {
          kind: "conflict",
          preservedLatest: false,
          backupPath: tmp,
          detail: `restore_swap_failed: ${msg}`,
        };
      }

      const postSwapStat = lstatIfExistsBigInt(tmp);
      const postSwapBytes =
        postSwapStat && !postSwapStat.isSymbolicLink() && postSwapStat.isFile()
          ? readRegularFileBytesIfExists(tmp, targetMaxBytes)
          : null;
      if (
        postSwapStat &&
        !postSwapStat.isSymbolicLink() &&
        postSwapStat.isFile() &&
        sameBigIntFileIdentity(postSwapStat, myStat) &&
        postSwapBytes !== null &&
        postSwapBytes.equals(contentBytes)
      ) {
        swappedOutExternal = false;
        return {
          kind: "conflict",
          preservedLatest: true,
          detail: "restored_external_version",
        };
      }

      // Version C raced into `filePath` right before Swap 2 (rename OR in-place on `myIno`), moving C into `tmp` and B into `filePath`.
      const matchesVersionB = (st: fs.BigIntStats | null, p: string): boolean => {
        if (!st || !sameBigIntFileIdentity(st, oldStat)) return false;
        if (oldStat.isSymbolicLink()) return st.isSymbolicLink();
        if (st.isSymbolicLink() || !st.isFile()) return false;
        if (versionBBytes === null) return true;
        try {
          const b = readRegularFileBytesIfExists(
            p,
            Math.max(MAX_SAFE_MANIFEST_BYTES, versionBBytes.byteLength),
          );
          return b !== null && b.equals(versionBBytes);
        } catch {
          return true;
        }
      };

      const afterTarget = lstatIfExistsBigInt(filePath);
      if (matchesVersionB(afterTarget, filePath)) {
        try {
          safeOpenat.renamex_swap(tmp, filePath);
          const postThirdStat = lstatIfExistsBigInt(tmp);
          if (matchesVersionB(postThirdStat, tmp)) {
            // Version C is back live on `filePath`, while `tmp` holds displaced Version B: preserve B in backup!
            preserveTmp = true;
            return {
              kind: "conflict",
              preservedLatest: false,
              backupPath: tmp,
              detail: "restored_latest_external_version",
            };
          }
        } catch {
          // Fall through with preserveTmp=true so Version C in `tmp` is preserved.
        }
      }

      preserveTmp = true;
      return {
        kind: "conflict",
        preservedLatest: false,
        backupPath: tmp,
        detail: "concurrent_external_writes_preserved_in_backup",
      };
    } catch (err) {
      if (swappedOutExternal) {
        notifyPreservedBackup("swap_error_preserved_in_backup");
      }
      throw err;
    } finally {
      if (!preserveTmp) {
        try {
          fs.unlinkSync(tmp);
        } catch {
          // ignore
        }
      }
    }
  }

  private atomicSwapStagedFileWithIdentity(params: {
    meetingId: string;
    subdir: MeetingSubdir | null;
    stagedBase: string;
    savedBase: string;
    stagedTmpPath: string;
    savedPath: string;
    expectedTargetStat: fs.BigIntStats;
    expectedTargetSha256: string;
    stagedStat: fs.BigIntStats;
    stagedSha256: string;
  }): CasResult {
    const expectedTargetHash = params.expectedTargetSha256.toLowerCase();
    const stagedHash = params.stagedSha256.toLowerCase();
    const preTarget = lstatIfExistsBigInt(params.savedPath);
    if (
      !preTarget ||
      preTarget.isSymbolicLink() ||
      !preTarget.isFile() ||
      !sameBigIntFileIdentity(preTarget, params.expectedTargetStat)
    ) {
      return { kind: "conflict", preservedLatest: true, detail: "changed_before_swap" };
    }

    safeOpenat.renamex_swap(params.stagedTmpPath, params.savedPath);

    let oldIdent:
      | { kind: "missing" }
      | { kind: "invalid" }
      | { kind: "ok"; bigintStat: fs.BigIntStats; sha256: string };
    let matchesExpected = false;
    try {
      oldIdent = this.readFileIdentityByFdUnlocked(
        params.meetingId,
        params.subdir,
        params.stagedBase,
      );
      if (
        oldIdent.kind === "ok" &&
        sameBigIntFileIdentity(oldIdent.bigintStat, params.expectedTargetStat) &&
        oldIdent.sha256 === expectedTargetHash
      ) {
        matchesExpected = true;
      }
    } catch (verifyErr) {
      let undoVerified = false;
      const preUndoTmpStat = (() => {
        try {
          return lstatIfExistsBigInt(params.stagedTmpPath);
        } catch {
          return null;
        }
      })();
      const curT = (() => {
        try {
          return this.readFileIdentityByFdUnlocked(
            params.meetingId,
            params.subdir,
            params.savedBase,
          );
        } catch {
          return null;
        }
      })();
      if (
        curT &&
        curT.kind === "ok" &&
        sameBigIntFileIdentity(curT.bigintStat, params.stagedStat) &&
        curT.sha256 === stagedHash
      ) {
        try {
          safeOpenat.renamex_swap(params.stagedTmpPath, params.savedPath);
          const postUndo = this.readFileIdentityByFdUnlocked(
            params.meetingId,
            params.subdir,
            params.stagedBase,
          );
          if (
            postUndo.kind === "ok" &&
            sameBigIntFileIdentity(postUndo.bigintStat, params.stagedStat) &&
            postUndo.sha256 === stagedHash
          ) {
            undoVerified = true;
          } else {
            const afterUndoTarget = lstatIfExistsBigInt(params.savedPath);
            if (
              afterUndoTarget &&
              (!preUndoTmpStat || sameBigIntFileIdentity(afterUndoTarget, preUndoTmpStat))
            ) {
              try {
                safeOpenat.renamex_swap(params.stagedTmpPath, params.savedPath);
              } catch {
                // Preserve latest in stagedTmpPath
              }
            }
          }
        } catch {
          // Leave undoVerified = false so backup remains preserved
        }
      }
      if (undoVerified) {
        throw verifyErr;
      }
      const vMsg = verifyErr instanceof Error ? verifyErr.message : String(verifyErr);
      return {
        kind: "conflict",
        preservedLatest: false,
        backupPath: params.stagedTmpPath,
        detail: `verify_error_preserved_in_backup: ${vMsg}`,
      };
    }

    if (matchesExpected) {
      return { kind: "swapped" };
    }

    const curTarget = this.readFileIdentityByFdUnlocked(
      params.meetingId,
      params.subdir,
      params.savedBase,
    );
    const targetUnchangedFromMine =
      curTarget.kind === "ok" &&
      sameBigIntFileIdentity(curTarget.bigintStat, params.stagedStat) &&
      curTarget.sha256 === stagedHash;
    if (!targetUnchangedFromMine) {
      return {
        kind: "conflict",
        preservedLatest: false,
        backupPath: params.stagedTmpPath,
        detail: "superseded_by_newer_external_write",
      };
    }

    try {
      safeOpenat.renamex_swap(params.stagedTmpPath, params.savedPath);
    } catch (swapBackErr) {
      const msg = swapBackErr instanceof Error ? swapBackErr.message : String(swapBackErr);
      return {
        kind: "conflict",
        preservedLatest: false,
        backupPath: params.stagedTmpPath,
        detail: `restore_swap_failed: ${msg}`,
      };
    }

    const postSwap = this.readFileIdentityByFdUnlocked(
      params.meetingId,
      params.subdir,
      params.stagedBase,
    );
    if (
      postSwap.kind === "ok" &&
      sameBigIntFileIdentity(postSwap.bigintStat, params.stagedStat) &&
      postSwap.sha256 === stagedHash
    ) {
      return {
        kind: "conflict",
        preservedLatest: true,
        detail: "restored_external_version",
      };
    }

    if (oldIdent.kind === "ok") {
      const afterTarget = lstatIfExistsBigInt(params.savedPath);
      if (afterTarget && sameBigIntFileIdentity(afterTarget, oldIdent.bigintStat)) {
        try {
          safeOpenat.renamex_swap(params.stagedTmpPath, params.savedPath);
          const postThird = lstatIfExistsBigInt(params.stagedTmpPath);
          if (postThird && sameBigIntFileIdentity(postThird, oldIdent.bigintStat)) {
            return {
              kind: "conflict",
              preservedLatest: false,
              backupPath: params.stagedTmpPath,
              detail: "restored_latest_external_version",
            };
          }
        } catch {
          // Preserve latest in stagedTmpPath
        }
      }
    }

    return {
      kind: "conflict",
      preservedLatest: false,
      backupPath: params.stagedTmpPath,
      detail: "concurrent_external_writes_preserved_in_backup",
    };
  }

  private validateAndNormalizeRange(raw: unknown, label: string): [number, number] {
    if (!Array.isArray(raw) || raw.length < 2) {
      throw new Error(`manifest.json 含非法时间区间 ${label}`);
    }
    const start = raw[0];
    const end = raw[1];
    if (typeof start !== "number" || !Number.isFinite(start) || typeof end !== "number" || !Number.isFinite(end)) {
      throw new Error(`manifest.json 含非数值时间区间 ${label}`);
    }
    return [start, end];
  }

  private normalizeChunkRecord(raw: unknown): ChunkRecord {
    if (!isPlainRecord(raw)) {
      throw new Error("manifest.json 含非法切片记录对象");
    }
    if (typeof raw.id !== "string" || !CHUNK_ID_RE.test(raw.id)) {
      throw new Error("manifest.json 含非法切片 ID");
    }
    if (typeof raw.index !== "number" || !Number.isSafeInteger(raw.index) || raw.index < 0) {
      throw new Error(`manifest.json 含非法切片序号: ${raw.id}`);
    }
    if (typeof raw.audioPath !== "string" || !CHUNK_REL_PATH_RE.test(raw.audioPath) || raw.audioPath.includes("..")) {
      throw new Error(`manifest.json 含非法切片路径: ${String(raw.audioPath)}`);
    }
    if (
      raw.micPath !== undefined &&
      raw.micPath !== null &&
      (typeof raw.micPath !== "string" || !CHUNK_REL_PATH_RE.test(raw.micPath) || raw.micPath.includes(".."))
    ) {
      throw new Error(`manifest.json 含非法麦克风切片路径: ${String(raw.micPath)}`);
    }
    if (
      raw.remotePath !== undefined &&
      raw.remotePath !== null &&
      (typeof raw.remotePath !== "string" || !CHUNK_REL_PATH_RE.test(raw.remotePath) || raw.remotePath.includes(".."))
    ) {
      throw new Error(`manifest.json 含非法远端切片路径: ${String(raw.remotePath)}`);
    }
    if (
      raw.timelinePath !== undefined &&
      raw.timelinePath !== null &&
      (typeof raw.timelinePath !== "string" || !TIMELINE_REL_PATH_RE.test(raw.timelinePath) || raw.timelinePath.includes(".."))
    ) {
      throw new Error(`manifest.json 含非法时间线路径: ${String(raw.timelinePath)}`);
    }
    const audioRangeSec = this.validateAndNormalizeRange(raw.audioRangeSec, `${raw.id}.audioRangeSec`);
    const responsibleRangeSec = this.validateAndNormalizeRange(raw.responsibleRangeSec, `${raw.id}.responsibleRangeSec`);
    if (typeof raw.durationSec !== "number" || !Number.isFinite(raw.durationSec) || raw.durationSec < 0) {
      throw new Error(`manifest.json 含非法切片时长: ${raw.id}`);
    }
    if (typeof raw.byteSize !== "number" || !Number.isSafeInteger(raw.byteSize) || raw.byteSize < 0) {
      throw new Error(`manifest.json 含非法切片大小: ${raw.id}`);
    }
    if (typeof raw.committedAt !== "string") {
      throw new Error(`manifest.json 含非法切片提交时间: ${raw.id}`);
    }

    return {
      index: raw.index,
      id: raw.id,
      audioPath: raw.audioPath,
      ...(typeof raw.micPath === "string" ? { micPath: raw.micPath } : {}),
      ...(typeof raw.remotePath === "string" ? { remotePath: raw.remotePath } : {}),
      ...(typeof raw.timelinePath === "string" ? { timelinePath: raw.timelinePath } : {}),
      audioRangeSec,
      responsibleRangeSec,
      durationSec: raw.durationSec,
      byteSize: raw.byteSize,
      committedAt: raw.committedAt,
    };
  }

  private validateTitle(title: string): string {
    if (!isWellFormedUnicode(title)) {
      throw new Error("会议标题包含非法未配对 Unicode 代理字符");
    }
    const trimmed = title.trim();
    if (!trimmed) {
      throw new Error("会议标题不能为空");
    }
    if (trimmed.length > MAX_MEETING_TITLE_CHARS) {
      throw new Error(`会议标题长度不能超过 ${MAX_MEETING_TITLE_CHARS} 个字符`);
    }
    return trimmed;
  }

  private preparePatchedManifestText(
    rawText: string,
    patches: Record<string, unknown>,
    meetingId: string,
  ): string {
    let patched = patchTopLevelJsonFields(rawText, patches);
    let bytes = Buffer.byteLength(patched, "utf8");
    if (bytes > MAX_SAFE_MANIFEST_BYTES) {
      patched = patchTopLevelJsonFields(rawText, patches, { compactMissing: true });
      bytes = Buffer.byteLength(patched, "utf8");
    }
    if (bytes > MAX_SAFE_MANIFEST_BYTES) {
      throw new Error(
        `更新后的 manifest.json (${bytes} B) 超过 16 MiB 安全读取上限，已拒绝写入: ${meetingId}`,
      );
    }
    return patched;
  }

  private preparePatchedManifestRawText(
    rawText: string,
    rawPatches: Map<string, string> | Record<string, string>,
    meetingId: string,
    removeKeys?: string[],
  ): string {
    let patched = patchTopLevelJsonRawFields(rawText, rawPatches, { removeKeys });
    let bytes = Buffer.byteLength(patched, "utf8");
    if (bytes > MAX_SAFE_MANIFEST_BYTES) {
      patched = patchTopLevelJsonRawFields(rawText, rawPatches, {
        compactMissing: true,
        removeKeys,
      });
      bytes = Buffer.byteLength(patched, "utf8");
    }
    if (bytes > MAX_SAFE_MANIFEST_BYTES) {
      throw new Error(
        `更新后的 manifest.json (${bytes} B) 超过 16 MiB 安全读取上限，已拒绝写入: ${meetingId}`,
      );
    }
    return patched;
  }

  private readManifestWithRaw(meetingId: string): {
    dir: string;
    manifest: MeetingManifest;
    rawText: string;
    bigintStat: fs.BigIntStats;
    rawBytes: Buffer;
  } {
    const dir = this.resolveMeetingDir(meetingId);
    const res = this.readMeetingFileByFd(meetingId, null, "manifest.json", {
      maxReadBytes: MAX_SAFE_MANIFEST_BYTES,
      allowTruncate: false,
    });
    if (res.kind === "missing") {
      throw new Error(`未找到会议记录: ${meetingId}`);
    }
    if (res.kind === "invalid") {
      throw new Error(`manifest.json 非法（符号链接、管道或非普通文件）: ${meetingId}`);
    }
    if (res.kind === "too_large") {
      throw new Error(`manifest.json 体积超过上限 (${res.size} B): ${meetingId}`);
    }

    const scanned = scanTopLevelJsonObject(res.content);
    let hostOriginRawToken: string | null = null;
    for (const entry of scanned.entries) {
      if (entry.key === "hostTimeOriginNs") {
        hostOriginRawToken = res.content.slice(entry.valStart, entry.valEnd);
      }
    }

    const parsedUnknown = JSON.parse(res.content) as unknown;
    if (!isPlainRecord(parsedUnknown) || parsedUnknown.id !== meetingId) {
      throw new Error(`manifest.json 内容与会议 ID 不匹配: ${meetingId}`);
    }
    if (typeof parsedUnknown.title !== "string") {
      throw new Error(`manifest.json 含非法标题字段: ${meetingId}`);
    }
    if (typeof parsedUnknown.mode !== "string" || !parsedUnknown.mode) {
      throw new Error(`manifest.json 含非法录制模式: ${meetingId}`);
    }
    if (typeof parsedUnknown.status !== "string" || !parsedUnknown.status) {
      throw new Error(`manifest.json 含非法状态字段: ${meetingId}`);
    }
    if (typeof parsedUnknown.createdAt !== "string" || !parsedUnknown.createdAt) {
      throw new Error(`manifest.json 含非法创建时间: ${meetingId}`);
    }
    if (
      parsedUnknown.schemaVersion !== undefined &&
      parsedUnknown.schemaVersion !== null &&
      (typeof parsedUnknown.schemaVersion !== "number" ||
        !Number.isSafeInteger(parsedUnknown.schemaVersion) ||
        parsedUnknown.schemaVersion < 1)
    ) {
      throw new Error(`manifest.json 含非法 schemaVersion: ${meetingId}`);
    }
    if (
      parsedUnknown.appTarget !== undefined &&
      parsedUnknown.appTarget !== null &&
      typeof parsedUnknown.appTarget !== "string"
    ) {
      throw new Error(`manifest.json 含非法 appTarget: ${meetingId}`);
    }
    if (
      parsedUnknown.endedAt !== undefined &&
      parsedUnknown.endedAt !== null &&
      typeof parsedUnknown.endedAt !== "string"
    ) {
      throw new Error(`manifest.json 含非法 endedAt: ${meetingId}`);
    }
    if (
      parsedUnknown.totalDurationSec !== undefined &&
      parsedUnknown.totalDurationSec !== null &&
      (typeof parsedUnknown.totalDurationSec !== "number" ||
        !Number.isFinite(parsedUnknown.totalDurationSec) ||
        parsedUnknown.totalDurationSec < 0)
    ) {
      throw new Error(`manifest.json 含非法 totalDurationSec: ${meetingId}`);
    }
    if (
      parsedUnknown.audioCleaned !== undefined &&
      parsedUnknown.audioCleaned !== null &&
      typeof parsedUnknown.audioCleaned !== "boolean"
    ) {
      throw new Error(`manifest.json 含非法 audioCleaned: ${meetingId}`);
    }
    if (
      parsedUnknown.failedChunkCount !== undefined &&
      parsedUnknown.failedChunkCount !== null &&
      (typeof parsedUnknown.failedChunkCount !== "number" ||
        !Number.isSafeInteger(parsedUnknown.failedChunkCount) ||
        parsedUnknown.failedChunkCount < 0)
    ) {
      throw new Error(`manifest.json 含非法 failedChunkCount: ${meetingId}`);
    }
    if (parsedUnknown.hostTimeOriginNs !== undefined && parsedUnknown.hostTimeOriginNs !== null) {
      if (
        typeof parsedUnknown.hostTimeOriginNs !== "number" ||
        hostOriginRawToken === null ||
        parseRawNonNegativeUint64(hostOriginRawToken) === null
      ) {
        throw new Error(`manifest.json 含非法 hostTimeOriginNs: ${meetingId}`);
      }
    }
    if (
      parsedUnknown.lastError !== undefined &&
      parsedUnknown.lastError !== null &&
      typeof parsedUnknown.lastError !== "string"
    ) {
      throw new Error(`manifest.json 含非法 lastError: ${meetingId}`);
    }

    let chunks: ChunkRecord[] = [];
    if (parsedUnknown.chunks !== undefined && parsedUnknown.chunks !== null) {
      if (!Array.isArray(parsedUnknown.chunks)) {
        throw new Error(`manifest.json 含非法 chunks 数组: ${meetingId}`);
      }
      chunks = parsedUnknown.chunks.map((c) => this.normalizeChunkRecord(c));
    }

    let gaps: GapRecord[] = [];
    if (parsedUnknown.gaps !== undefined && parsedUnknown.gaps !== null) {
      if (!Array.isArray(parsedUnknown.gaps)) {
        throw new Error(`manifest.json 含非法 gaps 数组: ${meetingId}`);
      }
      gaps = parsedUnknown.gaps.map((g) => {
        if (
          !isPlainRecord(g) ||
          typeof g.startSec !== "number" ||
          !Number.isFinite(g.startSec) ||
          typeof g.endSec !== "number" ||
          !Number.isFinite(g.endSec) ||
          typeof g.reason !== "string"
        ) {
          throw new Error(`manifest.json 含非法 gap 记录: ${meetingId}`);
        }
        return {
          startSec: g.startSec,
          endSec: g.endSec,
          reason: g.reason,
        };
      });
    }

    const mode = parsedUnknown.mode;
    const manifest: MeetingManifest = {
      schemaVersion:
        typeof parsedUnknown.schemaVersion === "number" ? parsedUnknown.schemaVersion : 1,
      id: parsedUnknown.id,
      title: parsedUnknown.title,
      mode,
      appTarget:
        typeof parsedUnknown.appTarget === "string"
          ? parsedUnknown.appTarget
          : mode === "dual"
            ? "all_system"
            : "mic_only",
      status: parsedUnknown.status,
      createdAt: parsedUnknown.createdAt,
      ...(typeof parsedUnknown.endedAt === "string" ? { endedAt: parsedUnknown.endedAt } : {}),
      totalDurationSec:
        typeof parsedUnknown.totalDurationSec === "number" ? parsedUnknown.totalDurationSec : 0,
      chunks,
      gaps,
      audioCleaned: parsedUnknown.audioCleaned === true,
      ...(typeof parsedUnknown.failedChunkCount === "number"
        ? { failedChunkCount: parsedUnknown.failedChunkCount }
        : {}),
      ...(typeof parsedUnknown.hostTimeOriginNs === "number"
        ? { hostTimeOriginNs: parsedUnknown.hostTimeOriginNs }
        : {}),
      ...(typeof parsedUnknown.lastError === "string" ? { lastError: parsedUnknown.lastError } : {}),
    };

    return {
      dir,
      manifest,
      rawText: res.content,
      bigintStat: res.bigintStat!,
      rawBytes: res.rawBytes!,
    };
  }

  private commitManifestPatchCAS(
    meetingId: string,
    dir: string,
    buildPatched: (latestRaw: string, latestManifest: MeetingManifest) => string | null,
    options?: {
      onBeforeCreateTmp?: (tmpBaseName: string) => void;
      onBeforeSwap?: (
        myStat: fs.BigIntStats,
        contentBytes: Buffer,
        tmpPath: string,
        expectedStat: fs.BigIntStats,
        expectedRawBytes: Buffer,
      ) => void;
      onSwapExecuted?: () => void;
      onSwapReverted?: () => void;
      onConflictBackup?: (info: { backupPath: string; snapshotRaw: string; detail: string }) => void;
    },
  ): { skipped: boolean; manifest: MeetingManifest; rawText: string; patchedText: string } {
    const manifestPath = path.join(dir, "manifest.json");
    for (let attempt = 0; attempt < 3; attempt += 1) {
      const { manifest: latestManifest, rawText: latestRaw, bigintStat, rawBytes } =
        this.readManifestWithRaw(meetingId);
      const nextText = buildPatched(latestRaw, latestManifest);
      if (nextText === null) {
        return { skipped: true, manifest: latestManifest, rawText: latestRaw, patchedText: latestRaw };
      }
      let attemptSwapped = false;
      const cas = this.atomicCompareAndSwapFile(manifestPath, nextText, bigintStat, rawBytes, {
        onBeforeCreateTmp: options?.onBeforeCreateTmp,
        onBeforeSwap: options?.onBeforeSwap,
        onSwapExecuted: () => {
          attemptSwapped = true;
          options?.onSwapExecuted?.();
        },
        onSwapReverted: () => {
          attemptSwapped = false;
          options?.onSwapReverted?.();
        },
        onPreserveBackup: (backupPath, detail) => {
          options?.onConflictBackup?.({
            backupPath,
            snapshotRaw: latestRaw,
            detail,
          });
        },
      });
      if (cas.kind === "swapped") {
        return { skipped: false, manifest: latestManifest, rawText: latestRaw, patchedText: nextText };
      }
      if (!cas.preservedLatest && cas.backupPath) {
        options?.onConflictBackup?.({
          backupPath: cas.backupPath,
          snapshotRaw: latestRaw,
          detail: cas.detail,
        });
        throw new Error(
          `写入 manifest.json 时发生外部冲突且回退失败，外部清单已备份于 ${cas.backupPath}: ${meetingId}`,
        );
      }
      if (attemptSwapped && cas.detail === "restored_external_version") {
        options?.onSwapReverted?.();
      }
    }
    throw new Error(`manifest.json 持续被外部并发修改，已放弃覆盖写入: ${meetingId}`);
  }

  private hasPendingCleanupRevertMarker(dir: string): boolean {
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch (err) {
      if ((err as NodeJS.ErrnoException | undefined)?.code === "ENOENT") {
        return false;
      }
      throw err;
    }
    for (const ent of entries) {
      if (!CLEANUP_STAGING_DIR_RE.test(ent.name)) continue;
      const stagingDir = path.join(dir, ent.name);
      const stLst = lstatIfExists(stagingDir);
      if (!stLst || stLst.isSymbolicLink() || !stLst.isDirectory()) continue;
      try {
        if (lstatIfExists(path.join(stagingDir, CLEANUP_REVERT_MARKER))) {
          return true;
        }
      } catch (err) {
        const code = (err as NodeJS.ErrnoException | undefined)?.code;
        if (code === "EACCES" || code === "EPERM" || code === "ENOTDIR") {
          continue;
        }
        throw err;
      }
    }
    return false;
  }

  private recoverPendingCleanupRevertMarkersUnlocked(meetingId: string, dir: string): void {
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch (err) {
      if ((err as NodeJS.ErrnoException | undefined)?.code === "ENOENT") {
        return;
      }
      throw err;
    }
    for (const ent of entries) {
      if (!CLEANUP_STAGING_DIR_RE.test(ent.name)) continue;
      const stagingDir = path.join(dir, ent.name);
      const stLst = lstatIfExists(stagingDir);
      if (!stLst || stLst.isSymbolicLink() || !stLst.isDirectory()) continue;
      const markerPath = path.join(stagingDir, CLEANUP_REVERT_MARKER);
      let markerLst: fs.Stats | null = null;
      try {
        markerLst = lstatIfExists(markerPath);
      } catch (err) {
        const code = (err as NodeJS.ErrnoException | undefined)?.code;
        if (code === "EACCES" || code === "EPERM" || code === "ENOTDIR") {
          continue;
        }
        throw err;
      }
      if (!markerLst) continue;
      if (markerLst.isSymbolicLink() || !markerLst.isFile()) {
        throw new Error(`拒绝清理异常恢复标记文件: ${CLEANUP_REVERT_MARKER}`);
      }
      // Must confirm this staging directory itself is listable before deciding zero staged audio remains.
      fs.readdirSync(stagingDir);

      const { manifest: latestM } = this.readManifestWithRaw(meetingId);
      const liveTargets = this.collectOwnedLiveTargets(dir, latestM, {
        strict: false,
        throwOnReadError: true,
      });
      const stagedScan = this.scanOwnedStagingFiles(dir, {
        requireWritable: false,
        throwOnUnreadable: false,
      });
      const hasRemainingAudio =
        liveTargets.length > 0 ||
        stagedScan.stagedFiles.length > 0 ||
        stagedScan.unreadableStagingDirs.length > 0;
      let deferredWhileActive = false;
      if (hasRemainingAudio) {
        this.commitManifestPatchCAS(meetingId, dir, (latestRaw, curM) => {
          deferredWhileActive = false;
          if (!curM.audioCleaned) {
            return null;
          }
          if (curM.status === "recording" || curM.status === "finalizing") {
            deferredWhileActive = true;
            return null;
          }
          return this.buildAudioCleanedFalseManifestText(latestRaw);
        });
      }
      if (deferredWhileActive) {
        continue;
      }
      try {
        fs.unlinkSync(markerPath);
      } catch (err) {
        if ((err as NodeJS.ErrnoException | undefined)?.code !== "ENOENT") {
          throw err;
        }
      }
      try {
        fs.rmdirSync(stagingDir);
      } catch {
        // ignore if non-empty
      }
    }
  }

  private handleLeaseCasConflictUnlocked(
    meetingId: string,
    dir: string,
    cas: CasResult,
  ): void {
    if (cas.kind !== "conflict" || cas.preservedLatest) {
      return;
    }
    if (!cas.backupPath) {
      throw new Error(`更新转写锁时发生并发冲突且未能恢复: ${cas.detail}`);
    }
    const backupBuf = readRegularFileBytesIfExists(cas.backupPath, 64 * 1024);
    if (backupBuf === null) {
      throw new Error(
        `更新转写锁时发生并发冲突且未能读取备份，已保留转写锁备份于 ${cas.backupPath}: ${cas.detail}`,
      );
    }
    const backupExp = parseLeaseExpiresAt(backupBuf.toString("utf8"));
    const curNow = this.readMeetingFileByFd(meetingId, null, LEASE_FILE_NAME, {
      maxReadBytes: 64 * 1024,
      allowTruncate: false,
    });
    const curExpNow = curNow.kind === "ok" ? parseLeaseExpiresAt(curNow.content) : null;
    const safeToDiscardBackup =
      (cas.detail === "superseded_by_newer_external_write" ||
        cas.detail === "restored_latest_external_version") &&
      (backupExp === null ||
        backupExp <= Date.now() ||
        (curExpNow !== null && curExpNow >= backupExp));
    if (safeToDiscardBackup) {
      try {
        fs.unlinkSync(cas.backupPath);
      } catch (err) {
        if ((err as NodeJS.ErrnoException | undefined)?.code !== "ENOENT") {
          throw err;
        }
      }
      return;
    }
    throw new Error(
      `更新转写锁时发生并发冲突且回退失败，已保留转写锁备份于 ${cas.backupPath}: ${cas.detail}`,
    );
  }

  private hasPendingLeaseBackupFile(dir: string): boolean {
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch (err) {
      if ((err as NodeJS.ErrnoException | undefined)?.code === "ENOENT") {
        return false;
      }
      throw err;
    }
    for (const ent of entries) {
      if (!LEASE_BACKUP_FILE_RE.test(ent.name)) continue;
      const lst = lstatIfExists(path.join(dir, ent.name));
      if (!lst || lst.isSymbolicLink() || !lst.isFile()) continue;
      return true;
    }
    return false;
  }

  private hasActiveLeaseBackupUnlocked(meetingId: string, dir: string): boolean {
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch (err) {
      if ((err as NodeJS.ErrnoException | undefined)?.code === "ENOENT") {
        return false;
      }
      throw err;
    }
    for (const ent of entries) {
      if (!LEASE_BACKUP_FILE_RE.test(ent.name)) continue;
      const lst = lstatIfExists(path.join(dir, ent.name));
      if (!lst || lst.isSymbolicLink() || !lst.isFile()) continue;
      const res = this.readMeetingFileByFd(meetingId, null, ent.name, {
        maxReadBytes: 64 * 1024,
        allowTruncate: false,
      });
      if (res.kind !== "ok") continue;
      const exp = parseLeaseExpiresAt(res.content);
      if (exp !== null && exp > Date.now()) {
        return true;
      }
    }
    return false;
  }

  private recoverLeaseBackupFilesUnlocked(meetingId: string, dir: string): void {
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch (err) {
      if ((err as NodeJS.ErrnoException | undefined)?.code === "ENOENT") {
        return;
      }
      throw err;
    }
    const lockPath = path.join(dir, LEASE_FILE_NAME);
    for (const ent of entries) {
      if (!LEASE_BACKUP_FILE_RE.test(ent.name)) continue;
      const backupPath = path.join(dir, ent.name);
      const lst = lstatIfExists(backupPath);
      if (!lst || lst.isSymbolicLink() || !lst.isFile()) continue;
      const backupRes = this.readMeetingFileByFd(meetingId, null, ent.name, {
        maxReadBytes: 64 * 1024,
        allowTruncate: false,
      });
      if (backupRes.kind !== "ok") continue;
      const backupExp = parseLeaseExpiresAt(backupRes.content);
      if (backupExp !== null && backupExp > Date.now()) {
        this.assertSafeLeaseTarget(dir);
        let restored = false;
        for (let attempt = 0; attempt < 5; attempt += 1) {
          const curLease = this.readMeetingFileByFd(meetingId, null, LEASE_FILE_NAME, {
            maxReadBytes: 64 * 1024,
            allowTruncate: false,
          });
          if (curLease.kind === "invalid" || curLease.kind === "too_large") {
            throw new Error(`拒绝清理异常转写锁目标: ${LEASE_FILE_NAME}`);
          }
          if (curLease.kind === "missing") {
            this.createLeaseExclUnlocked(dir, backupRes.content);
            const verified = this.readMeetingFileByFd(meetingId, null, LEASE_FILE_NAME, {
              maxReadBytes: 64 * 1024,
              allowTruncate: false,
            });
            const verExp = verified.kind === "ok" ? parseLeaseExpiresAt(verified.content) : null;
            if (verExp !== null && verExp >= backupExp) {
              restored = true;
              break;
            }
            continue;
          }
          const curExp = parseLeaseExpiresAt(curLease.content);
          if (curExp !== null && curExp >= backupExp) {
            restored = true;
            break;
          }
          const cas = this.atomicCompareAndSwapFile(
            lockPath,
            backupRes.content,
            curLease.bigintStat!,
            curLease.rawBytes!,
          );
          if (cas.kind === "swapped") {
            const postSwapLease = this.readMeetingFileByFd(meetingId, null, LEASE_FILE_NAME, {
              maxReadBytes: 64 * 1024,
              allowTruncate: false,
            });
            const postSwapExp =
              postSwapLease.kind === "ok" ? parseLeaseExpiresAt(postSwapLease.content) : null;
            if (postSwapExp !== null && postSwapExp >= backupExp) {
              restored = true;
              break;
            }
            continue;
          }
          if (!cas.preservedLatest) {
            this.handleLeaseCasConflictUnlocked(meetingId, dir, cas);
            continue;
          }
        }
        const finalCheck = this.readMeetingFileByFd(meetingId, null, LEASE_FILE_NAME, {
          maxReadBytes: 64 * 1024,
          allowTruncate: false,
        });
        const finalExp =
          finalCheck.kind === "ok" ? parseLeaseExpiresAt(finalCheck.content) : null;
        if (!restored || finalExp === null || finalExp < backupExp) {
          throw new Error(`恢复转写锁备份失败，已保留备份于 ${backupPath}: ${meetingId}`);
        }
        try {
          fs.unlinkSync(backupPath);
        } catch (err) {
          if ((err as NodeJS.ErrnoException | undefined)?.code !== "ENOENT") {
            throw err;
          }
        }
      } else if (backupExp !== null && backupExp <= Date.now()) {
        try {
          fs.unlinkSync(backupPath);
        } catch (err) {
          if ((err as NodeJS.ErrnoException | undefined)?.code !== "ENOENT") {
            throw err;
          }
        }
      }
    }
  }

  private clearMatchingLeaseUnlocked(
    meetingId: string,
    dir: string,
    expectedPrevLeaseContent: string | null | undefined,
    options?: {
      onSwapped?: () => void;
      restoreExpiredIfBlocked?: boolean;
    },
  ): boolean {
    this.assertSafeLeaseTarget(dir);
    if (typeof expectedPrevLeaseContent !== "string") {
      return false;
    }
    const manifestPath = path.join(dir, "manifest.json");
    const isBlockedByManifest = (m: MeetingManifest): boolean =>
      m.status === "recording" ||
      m.status === "finalizing" ||
      this.getTranscriptChunkStatus(meetingId, dir, m.chunks).missingChunkIds.length > 0;
    const restoreExpiredLeaseIfNeeded = () => {
      this.rollbackLeaseSafelyUnlocked(meetingId, dir, {
        leaseAction: "clear",
        prevLeaseContent: expectedPrevLeaseContent,
      });
    };

    const initialMan = this.readManifestWithRaw(meetingId);
    if (isBlockedByManifest(initialMan.manifest)) {
      if (options?.restoreExpiredIfBlocked) {
        const curNow = this.readMeetingFileByFd(meetingId, null, LEASE_FILE_NAME, {
          maxReadBytes: 64 * 1024,
          allowTruncate: false,
        });
        if (curNow.kind === "invalid" || curNow.kind === "too_large") {
          throw new Error(`拒绝清理异常转写锁目标: ${LEASE_FILE_NAME}`);
        }
        if (curNow.kind === "missing" || isLeaseExpiredOrInvalid(curNow.content)) {
          restoreExpiredLeaseIfNeeded();
        }
      }
      return false;
    }
    const lockPath = path.join(dir, LEASE_FILE_NAME);
    const curLease = this.readMeetingFileByFd(meetingId, null, LEASE_FILE_NAME, {
      maxReadBytes: 64 * 1024,
      allowTruncate: false,
    });
    if (curLease.kind === "missing") {
      if (options?.restoreExpiredIfBlocked) {
        const curMan = this.readManifestWithRaw(meetingId).manifest;
        if (isBlockedByManifest(curMan)) {
          restoreExpiredLeaseIfNeeded();
        }
      }
      return false;
    }
    if (curLease.kind !== "ok") {
      throw new Error(`拒绝清理异常转写锁目标: ${LEASE_FILE_NAME}`);
    }
    if (isLeaseExpiredOrInvalid(curLease.content)) {
      if (options?.restoreExpiredIfBlocked) {
        const curMan = this.readManifestWithRaw(meetingId).manifest;
        if (isBlockedByManifest(curMan)) {
          restoreExpiredLeaseIfNeeded();
        }
      }
      return false;
    }
    if (curLease.content !== expectedPrevLeaseContent) {
      return false;
    }

    const preSwapManStat = lstatIfExistsBigInt(manifestPath);
    if (
      !preSwapManStat ||
      preSwapManStat.isSymbolicLink() ||
      !preSwapManStat.isFile() ||
      !sameBigIntFileIdentity(preSwapManStat, initialMan.bigintStat)
    ) {
      const refreshedMan = this.readManifestWithRaw(meetingId).manifest;
      if (isBlockedByManifest(refreshedMan)) {
        return false;
      }
    }

    // Atomically swap with an expired tombstone instead of unlinking so a racing renewal cannot be deleted.
    const cas = this.atomicCompareAndSwapFile(
      lockPath,
      EXPIRED_LEASE_JSON,
      curLease.bigintStat!,
      curLease.rawBytes!,
    );
    this.handleLeaseCasConflictUnlocked(meetingId, dir, cas);
    if (cas.kind === "swapped") {
      options?.onSwapped?.();
      let postBlocked = false;
      try {
        const postMan = this.readManifestWithRaw(meetingId).manifest;
        postBlocked = isBlockedByManifest(postMan);
      } catch (postErr) {
        restoreExpiredLeaseIfNeeded();
        throw postErr;
      }
      if (postBlocked) {
        restoreExpiredLeaseIfNeeded();
        return false;
      }
      return true;
    }
    return false;
  }

  private rollbackAndMergeManifestUnlocked(params: {
    meetingId: string;
    dir: string;
    nextTitle: string;
    fallbackPrevTitle: string;
    initialConflict: {
      backupPath: string;
      snapshotRaw: string;
      attemptedTitleToken: string | null;
      detail: string;
    } | null;
  }): {
    resolved: boolean;
    mergedAndDeletedBackups: string[];
    retainedBackups: string[];
    deferredMerges: PendingManifestMergeRecord[];
  } {
    type ConflictItem = {
      backupPath: string;
      snapshotRaw: string;
      attemptedTitleToken: string | null;
      detail: string;
    };
    const REQUIRED_MANIFEST_KEYS = new Set(["id", "title", "mode", "status", "createdAt"]);
    const nextTitleToken = JSON.stringify(params.nextTitle);
    const fallbackPrevTitleToken = JSON.stringify(params.fallbackPrevTitle);
    const queue: Array<ConflictItem | null> = [params.initialConflict];
    const mergedAndDeletedBackups: string[] = [];
    const retainedBackups: string[] = [];
    const deferredMerges: PendingManifestMergeRecord[] = [];

    for (let pass = 0; pass < 8 && queue.length > 0; pass += 1) {
      const current = queue.shift()!;
      let displacedTokens: Map<string, string> | null = null;
      let snapshotTokens: Map<string, string> | null = null;
      let backupReadIoError = false;
      if (current !== null) {
        let displacedBuf: Buffer | null = null;
        for (let readTry = 0; readTry < 2; readTry += 1) {
          try {
            displacedBuf = readRegularFileBytesIfExists(
              current.backupPath,
              MAX_SAFE_MANIFEST_BYTES,
            );
            backupReadIoError = false;
            break;
          } catch {
            displacedBuf = null;
            backupReadIoError = true;
          }
        }
        if (!backupReadIoError && displacedBuf) {
          try {
            const displacedText = displacedBuf.toString("utf8");
            const parsedDisp = JSON.parse(displacedText) as unknown;
            const parsedSnap = JSON.parse(current.snapshotRaw) as unknown;
            if (
              isPlainRecord(parsedDisp) &&
              parsedDisp.id === params.meetingId &&
              typeof parsedDisp.title === "string" &&
              typeof parsedDisp.mode === "string" &&
              parsedDisp.mode.length > 0 &&
              typeof parsedDisp.status === "string" &&
              parsedDisp.status.length > 0 &&
              typeof parsedDisp.createdAt === "string" &&
              parsedDisp.createdAt.length > 0 &&
              isPlainRecord(parsedSnap)
            ) {
              displacedTokens = extractTopLevelRawTokens(displacedText);
              snapshotTokens = extractTopLevelRawTokens(current.snapshotRaw);
            }
          } catch {
            displacedTokens = null;
            snapshotTokens = null;
          }
        }
      }

      if (current !== null && backupReadIoError) {
        try {
          const snapPath = this.writeStagingTempFile(
            params.dir,
            "manifest-snap",
            current.snapshotRaw,
          );
          deferredMerges.push({
            backupRelPath: path.basename(current.backupPath),
            snapshotRelPath: path.basename(snapPath),
            nextTitle: params.nextTitle,
            fallbackPrevTitle: params.fallbackPrevTitle,
            attemptedTitleToken: current.attemptedTitleToken,
          });
        } catch {
          retainedBackups.push(current.backupPath);
          for (const rem of queue) {
            if (rem !== null) retainedBackups.push(rem.backupPath);
          }
          return {
            resolved: false,
            mergedAndDeletedBackups,
            retainedBackups,
            deferredMerges,
          };
        }
      }

      let allDisplacedMerged =
        current === null || (displacedTokens !== null && snapshotTokens !== null);
      let lastAttemptedTitleToken: string | null = null;
      let nestedConflict: ConflictItem | null = null;

      try {
        this.commitManifestPatchCAS(
          params.meetingId,
          params.dir,
          (latestRaw, latestM) => {
            allDisplacedMerged =
              current === null || (displacedTokens !== null && snapshotTokens !== null);
            const rawPatches = new Map<string, string>();
            const removeKeys: string[] = [];
            let latestTokens: Map<string, string> | null = null;
            try {
              latestTokens = extractTopLevelRawTokens(latestRaw);
            } catch {
              latestTokens = null;
              allDisplacedMerged = false;
            }

            if (displacedTokens && snapshotTokens && latestTokens) {
              const snapTitle = snapshotTokens.get("title");
              const dispTitle = displacedTokens.get("title");
              const liveTitle = latestTokens.get("title");
              if (!rawJsonTokensEqual(dispTitle, snapTitle)) {
                if (rawJsonTokensEqual(liveTitle, dispTitle)) {
                  // Already reflects displaced writer's title.
                } else if (
                  rawJsonTokensEqual(liveTitle, snapTitle) ||
                  rawJsonTokensEqual(liveTitle, nextTitleToken) ||
                  (current?.attemptedTitleToken !== null &&
                    current?.attemptedTitleToken !== undefined &&
                    rawJsonTokensEqual(liveTitle, current.attemptedTitleToken))
                ) {
                  if (dispTitle !== undefined) {
                    rawPatches.set("title", dispTitle);
                  } else {
                    allDisplacedMerged = false;
                  }
                } else {
                  allDisplacedMerged = false;
                }
              } else if (rawJsonTokensEqual(liveTitle, nextTitleToken)) {
                rawPatches.set(
                  "title",
                  !rawJsonTokensEqual(snapTitle, nextTitleToken)
                    ? (snapTitle ?? fallbackPrevTitleToken)
                    : fallbackPrevTitleToken,
                );
              }

              for (const [k, dispVal] of displacedTokens.entries()) {
                if (k === "title") continue;
                const snapVal = snapshotTokens.get(k);
                const liveVal = latestTokens.get(k);
                if (!rawJsonTokensEqual(dispVal, snapVal)) {
                  if (rawJsonTokensEqual(liveVal, dispVal)) {
                    continue;
                  }
                  if (rawJsonTokensEqual(liveVal, snapVal)) {
                    rawPatches.set(k, dispVal);
                  } else {
                    allDisplacedMerged = false;
                  }
                }
              }

              for (const [k, snapVal] of snapshotTokens.entries()) {
                if (k === "title") continue;
                if (!displacedTokens.has(k)) {
                  const liveVal = latestTokens.get(k);
                  if (liveVal === undefined) {
                    continue;
                  }
                  if (rawJsonTokensEqual(liveVal, snapVal) && !REQUIRED_MANIFEST_KEYS.has(k)) {
                    removeKeys.push(k);
                  } else {
                    allDisplacedMerged = false;
                  }
                }
              }
            } else if (latestM.title === params.nextTitle) {
              rawPatches.set("title", fallbackPrevTitleToken);
            }

            lastAttemptedTitleToken =
              rawPatches.get("title") ?? latestTokens?.get("title") ?? null;
            if (rawPatches.size === 0 && removeKeys.length === 0) {
              return null;
            }
            return this.preparePatchedManifestRawText(
              latestRaw,
              rawPatches,
              params.meetingId,
              removeKeys,
            );
          },
          {
            onConflictBackup: (info) => {
              nestedConflict = {
                ...info,
                attemptedTitleToken: lastAttemptedTitleToken,
              };
            },
          },
        );

        if (current !== null) {
          if (allDisplacedMerged) {
            try {
              fs.unlinkSync(current.backupPath);
              mergedAndDeletedBackups.push(current.backupPath);
            } catch (unlinkErr) {
              if ((unlinkErr as NodeJS.ErrnoException | undefined)?.code === "ENOENT") {
                mergedAndDeletedBackups.push(current.backupPath);
              } else {
                retainedBackups.push(current.backupPath);
              }
            }
          } else {
            retainedBackups.push(current.backupPath);
          }
        }
      } catch {
        if (nestedConflict !== null) {
          queue.push(nestedConflict);
          if (current !== null && !backupReadIoError) {
            queue.push(current);
          } else if (current !== null) {
            retainedBackups.push(current.backupPath);
          }
        } else {
          if (current !== null) {
            retainedBackups.push(current.backupPath);
          }
          for (const rem of queue) {
            if (rem !== null) retainedBackups.push(rem.backupPath);
          }
          return {
            resolved: false,
            mergedAndDeletedBackups,
            retainedBackups,
            deferredMerges,
          };
        }
      }
    }

    if (queue.length > 0) {
      for (const rem of queue) {
        if (rem !== null) retainedBackups.push(rem.backupPath);
      }
      return {
        resolved: false,
        mergedAndDeletedBackups,
        retainedBackups,
        deferredMerges,
      };
    }

    return {
      resolved: true,
      mergedAndDeletedBackups,
      retainedBackups,
      deferredMerges,
    };
  }

  private recoverPendingSaveTxUnlocked(meetingId: string, dir: string): void {
    if (this.hasPendingLeaseBackupFile(dir)) {
      this.readManifestWithRaw(meetingId);
      this.recoverLeaseBackupFilesUnlocked(meetingId, dir);
    }

    const txPath = path.join(dir, SAVE_TX_FILE_NAME);
    const txLst = lstatIfExists(txPath);
    if (txLst) {
      // Validate manifest.json BEFORE reading or pruning .save-tx.json so invalid/corrupt meetings stay untouched.
      const {
        manifest,
        rawText: manifestRawText,
        bigintStat: manifestStat,
        rawBytes: manifestRawBytes,
      } = this.readManifestWithRaw(meetingId);

      const txRes = this.readMeetingFileByFd(meetingId, null, SAVE_TX_FILE_NAME, {
        maxReadBytes: SAVE_TX_MAX_BYTES,
        allowTruncate: false,
      });
      if (txRes.kind !== "missing") {
        if (txRes.kind === "invalid") {
          throw new Error(`拒绝访问异常事务日志文件: ${SAVE_TX_FILE_NAME}`);
        }
        if (txRes.kind === "too_large") {
          throw new Error(`事务日志文件超过安全上限，拒绝自动丢弃: ${SAVE_TX_FILE_NAME}`);
        }

        const unlinkTxFile = () => {
          if (txLst.isSymbolicLink() || !txLst.isFile()) {
            throw new Error(`拒绝清理异常事务日志文件: ${SAVE_TX_FILE_NAME}`);
          }
          try {
            fs.unlinkSync(txPath);
          } catch (err) {
            if ((err as NodeJS.ErrnoException | undefined)?.code !== "ENOENT") {
              throw err;
            }
          }
        };

        let rec: unknown;
        let parsedOk = true;
        try {
          rec = JSON.parse(txRes.content) as unknown;
        } catch {
          parsedOk = false;
        }

        if (
          !parsedOk ||
          !isPlainRecord(rec) ||
          rec.version !== 1 ||
          rec.meetingId !== meetingId ||
          typeof rec.savedRelPath !== "string" ||
          typeof rec.stagedTmpRelPath !== "string"
        ) {
          unlinkTxFile();
        } else {
          const txMode =
            rec.txMode === "body_only"
              ? "body_only"
              : (rec.txMode === undefined || rec.txMode === "title_and_body") &&
                  typeof rec.targetTitle === "string"
                ? "title_and_body"
                : null;
          const leaseAction =
            rec.leaseAction === undefined
              ? "none"
              : rec.leaseAction === "none" || rec.leaseAction === "touch" || rec.leaseAction === "clear"
                ? rec.leaseAction
                : null;
          const prevLeaseValid =
            rec.prevLeaseContent === undefined ||
            rec.prevLeaseContent === null ||
            typeof rec.prevLeaseContent === "string";
          const appliedLeaseValid =
            rec.appliedLeaseContent === undefined ||
            rec.appliedLeaseContent === null ||
            typeof rec.appliedLeaseContent === "string";
          const phaseValid =
            rec.phase === undefined || rec.phase === "pending" || rec.phase === "aborted";
          const createdAtValid =
            rec.createdAt === undefined ||
            (typeof rec.createdAt === "number" && Number.isFinite(rec.createdAt));
          const prevTitleValid =
            rec.prevManifestTitle === undefined || typeof rec.prevManifestTitle === "string";
          const swapTmpValid =
            rec.manifestSwapTmpRelPath === undefined ||
            (typeof rec.manifestSwapTmpRelPath === "string" &&
              MANIFEST_BACKUP_FILE_RE.test(rec.manifestSwapTmpRelPath));
          const preSwapSnapValid =
            rec.preSwapManifestSnapRelPath === undefined ||
            (typeof rec.preSwapManifestSnapRelPath === "string" &&
              MANIFEST_SNAP_FILE_RE.test(rec.preSwapManifestSnapRelPath));
          const rfMovedExclValid =
            rec.rfMovedExcl === undefined || typeof rec.rfMovedExcl === "boolean";

          let expectedIdentityValid = true;
          let expectedIdentity: FileIdentityRecord | undefined;
          let matchesExpectedManifest = false;
          if (rec.expectedManifestIdentity !== undefined) {
            if (!isValidFileIdentityRecord(rec.expectedManifestIdentity)) {
              expectedIdentityValid = false;
            } else {
              expectedIdentity = rec.expectedManifestIdentity;
              matchesExpectedManifest = matchesFileIdentity(
                manifestStat,
                manifestRawBytes,
                expectedIdentity,
              );
            }
          }

          let preSwapIdentityValid = true;
          let expectedPreSwapIdentity: FileIdentityRecord | undefined;
          if (rec.expectedPreSwapManifestIdentity !== undefined) {
            if (!isValidFileIdentityRecord(rec.expectedPreSwapManifestIdentity)) {
              preSwapIdentityValid = false;
            } else {
              expectedPreSwapIdentity = rec.expectedPreSwapManifestIdentity;
            }
          }

          let prevSavedValid = true;
          let prevSavedIdentity: SavedFileIdentity | undefined;
          if (rec.prevSavedIdentity !== undefined) {
            if (!isValidSavedFileIdentity(rec.prevSavedIdentity)) {
              prevSavedValid = false;
            } else {
              prevSavedIdentity = rec.prevSavedIdentity;
            }
          }

          let stagedIdentityValid = true;
          let stagedFileIdentity: FileIdentityRecord | undefined;
          if (rec.stagedFileIdentity !== undefined) {
            if (!isValidFileIdentityRecord(rec.stagedFileIdentity)) {
              stagedIdentityValid = false;
            } else {
              stagedFileIdentity = rec.stagedFileIdentity;
            }
          }

          let pendingMergesValid = true;
          let pendingManifestMerges: PendingManifestMergeRecord[] | undefined;
          if (rec.pendingManifestMerges !== undefined) {
            if (
              !Array.isArray(rec.pendingManifestMerges) ||
              !rec.pendingManifestMerges.every((m) => isValidPendingMergeRecord(m))
            ) {
              pendingMergesValid = false;
            } else {
              pendingManifestMerges = rec.pendingManifestMerges;
            }
          }

          const validSaved =
            rec.savedRelPath === "notes.md" ||
            rec.savedRelPath === "transcript.md" ||
            /^transcripts\/[a-zA-Z0-9_-]{3,32}\.md$/.test(rec.savedRelPath);
          const savedDirRel = path.posix.dirname(rec.savedRelPath);
          const stagedDirRel = path.posix.dirname(rec.stagedTmpRelPath);
          const stagedBase = path.posix.basename(rec.stagedTmpRelPath);
          const validStaged =
            savedDirRel === stagedDirRel &&
            !rec.stagedTmpRelPath.includes("..") &&
            /^\.[a-zA-Z0-9._-]+\.[0-9a-f-]+\.tmp$/i.test(stagedBase);

          if (
            !txMode ||
            !leaseAction ||
            !prevLeaseValid ||
            !appliedLeaseValid ||
            !phaseValid ||
            !createdAtValid ||
            !prevTitleValid ||
            !swapTmpValid ||
            !preSwapSnapValid ||
            !rfMovedExclValid ||
            !expectedIdentityValid ||
            !preSwapIdentityValid ||
            !prevSavedValid ||
            !stagedIdentityValid ||
            !pendingMergesValid ||
            !validSaved ||
            !validStaged
          ) {
            unlinkTxFile();
          } else {
            const unlinkPreSwapSnap = () => {
              if (typeof rec.preSwapManifestSnapRelPath !== "string") return;
              const snapPath = path.join(dir, rec.preSwapManifestSnapRelPath);
              const snapLst = lstatIfExists(snapPath);
              if (snapLst && !snapLst.isSymbolicLink() && snapLst.isFile()) {
                try {
                  fs.unlinkSync(snapPath);
                } catch (err) {
                  if ((err as NodeJS.ErrnoException | undefined)?.code !== "ENOENT") {
                    throw err;
                  }
                }
              }
            };
            const unlinkBodyOnlySwapTmp = () => {
              if (txMode !== "body_only" || typeof rec.manifestSwapTmpRelPath !== "string") {
                return;
              }
              const swapTmpPath = path.join(dir, rec.manifestSwapTmpRelPath);
              const swapTmpLst = lstatIfExists(swapTmpPath);
              if (swapTmpLst && !swapTmpLst.isSymbolicLink() && swapTmpLst.isFile()) {
                try {
                  fs.unlinkSync(swapTmpPath);
                } catch (err) {
                  if ((err as NodeJS.ErrnoException | undefined)?.code !== "ENOENT") {
                    throw err;
                  }
                }
              }
            };
            const cleanupTxAndPreSwapSnap = () => {
              unlinkBodyOnlySwapTmp();
              unlinkPreSwapSnap();
              unlinkTxFile();
            };

            let targetParentDir: string | null = dir;
            if (savedDirRel === "transcripts") {
              targetParentDir = this.assertSafeSubdir(dir, "transcripts");
            }
            const savedSubdir: MeetingSubdir | null =
              savedDirRel === "transcripts" ? "transcripts" : null;
            const savedBase = path.posix.basename(rec.savedRelPath);
            const stagedTmpPath = targetParentDir ? path.join(targetParentDir, stagedBase) : null;
            const savedPath = targetParentDir ? path.join(targetParentDir, savedBase) : null;
            const stagedLst = stagedTmpPath ? lstatIfExists(stagedTmpPath) : null;

            const runMergeMustResolve = (mergeCfg: {
              backupPath: string;
              snapshotRaw: string;
              nextTitle: string;
              fallbackPrevTitle: string;
              attemptedTitleToken: string | null;
              detail: string;
            }) => {
              const res = this.rollbackAndMergeManifestUnlocked({
                meetingId,
                dir,
                nextTitle: mergeCfg.nextTitle,
                fallbackPrevTitle: mergeCfg.fallbackPrevTitle,
                initialConflict: {
                  backupPath: mergeCfg.backupPath,
                  snapshotRaw: mergeCfg.snapshotRaw,
                  attemptedTitleToken: mergeCfg.attemptedTitleToken,
                  detail: mergeCfg.detail,
                },
              });
              for (const extraSnap of res.deferredMerges) {
                try {
                  fs.unlinkSync(path.join(dir, extraSnap.snapshotRelPath));
                } catch {
                  // ignore
                }
              }
              if (!res.resolved || res.deferredMerges.length > 0) {
                throw new Error(`恢复清单并发备份失败，已保留事务日志等待下次重试: ${meetingId}`);
              }
            };

            if (rec.phase === "aborted") {
              if (stagedLst) {
                if (stagedLst.isSymbolicLink() || !stagedLst.isFile()) {
                  throw new Error(`恢复暂存写入时检测到异常暂存文件: ${rec.stagedTmpRelPath}`);
                }
                try {
                  fs.unlinkSync(stagedTmpPath!);
                } catch (err) {
                  if ((err as NodeJS.ErrnoException | undefined)?.code !== "ENOENT") {
                    throw err;
                  }
                }
              }
              if (pendingManifestMerges && pendingManifestMerges.length > 0) {
                for (const pm of pendingManifestMerges) {
                  const bPath = path.join(dir, pm.backupRelPath);
                  const sPath = path.join(dir, pm.snapshotRelPath);
                  const bLst = lstatIfExists(bPath);
                  if (!bLst) {
                    try {
                      fs.unlinkSync(sPath);
                    } catch {
                      // ignore
                    }
                    continue;
                  }
                  if (bLst.isSymbolicLink() || !bLst.isFile()) {
                    throw new Error(`拒绝访问异常清单备份文件: ${pm.backupRelPath}`);
                  }
                  const sRes = this.readMeetingFileByFd(meetingId, null, pm.snapshotRelPath, {
                    maxReadBytes: MAX_SAFE_MANIFEST_BYTES,
                    allowTruncate: false,
                  });
                  if (sRes.kind !== "ok") {
                    throw new Error(`无法读取事务恢复快照文件: ${pm.snapshotRelPath}`);
                  }
                  runMergeMustResolve({
                    backupPath: bPath,
                    snapshotRaw: sRes.content,
                    nextTitle: pm.nextTitle,
                    fallbackPrevTitle: pm.fallbackPrevTitle,
                    attemptedTitleToken: pm.attemptedTitleToken,
                    detail: "deferred_backup_merge",
                  });
                  try {
                    fs.unlinkSync(sPath);
                  } catch (err) {
                    if ((err as NodeJS.ErrnoException | undefined)?.code !== "ENOENT") {
                      throw err;
                    }
                  }
                }
              }
              cleanupTxAndPreSwapSnap();
            } else {
              const expectedPrevLeaseContent =
                typeof rec.prevLeaseContent === "string" || rec.prevLeaseContent === null
                  ? rec.prevLeaseContent
                  : undefined;
              const expectedAppliedLeaseContent =
                typeof rec.appliedLeaseContent === "string" || rec.appliedLeaseContent === null
                  ? rec.appliedLeaseContent
                  : undefined;

              const applyCommittedLease = () => {
                if (leaseAction === "clear") {
                  this.clearMatchingLeaseUnlocked(meetingId, dir, expectedPrevLeaseContent, {
                    restoreExpiredIfBlocked: true,
                  });
                } else if (leaseAction === "touch") {
                  this.assertSafeLeaseTarget(dir);
                  this.touchTranscriptionLeaseUnlocked(meetingId, dir);
                }
              };

              const curTxState: Record<string, unknown> = { ...rec };
              const abortCurrentWal = () => {
                this.rollbackLeaseSafelyUnlocked(meetingId, dir, {
                  leaseAction,
                  prevLeaseContent: expectedPrevLeaseContent,
                  appliedLeaseContent:
                    typeof curTxState.appliedLeaseContent === "string" ||
                    curTxState.appliedLeaseContent === null
                      ? (curTxState.appliedLeaseContent as string | null)
                      : expectedAppliedLeaseContent,
                });
                this.atomicWriteFile(txPath, JSON.stringify({ ...curTxState, phase: "aborted" }));
                if (stagedTmpPath) {
                  try {
                    fs.unlinkSync(stagedTmpPath);
                  } catch (err) {
                    if ((err as NodeJS.ErrnoException | undefined)?.code !== "ENOENT") {
                      throw err;
                    }
                  }
                }
                cleanupTxAndPreSwapSnap();
              };

              const safeRevertOwnManifestTitle = () => {
                if (
                  expectedIdentity === undefined ||
                  typeof rec.prevManifestTitle !== "string" ||
                  typeof rec.targetTitle !== "string"
                ) {
                  return;
                }
                const curM = this.readManifestWithRaw(meetingId);
                if (
                  curM.manifest.title === rec.targetTitle &&
                  matchesFileIdentity(curM.bigintStat, curM.rawBytes, expectedIdentity)
                ) {
                  const revertedText = this.preparePatchedManifestText(
                    curM.rawText,
                    { title: rec.prevManifestTitle },
                    meetingId,
                  );
                  this.atomicCompareAndSwapFile(
                    path.join(dir, "manifest.json"),
                    revertedText,
                    curM.bigintStat,
                    curM.rawBytes,
                  );
                }
              };

              if (stagedLst) {
                if (stagedLst.isSymbolicLink() || !stagedLst.isFile()) {
                  throw new Error(`恢复暂存写入时检测到异常暂存文件: ${rec.stagedTmpRelPath}`);
                }

                let swapConflictedWithExternal = false;
                if (txMode === "title_and_body" && typeof rec.manifestSwapTmpRelPath === "string") {
                  const swapTmpPath = path.join(dir, rec.manifestSwapTmpRelPath);
                  const swapTmpLst = lstatIfExistsBigInt(swapTmpPath);
                  if (swapTmpLst && !swapTmpLst.isSymbolicLink() && swapTmpLst.isFile()) {
                    const swapTmpRes = this.readMeetingFileByFd(
                      meetingId,
                      null,
                      rec.manifestSwapTmpRelPath,
                      { maxReadBytes: MAX_SAFE_MANIFEST_BYTES, allowTruncate: false },
                    );
                    if (swapTmpRes.kind === "ok") {
                      const matchesPreSwap =
                        expectedPreSwapIdentity !== undefined &&
                        matchesFileIdentity(
                          swapTmpRes.bigintStat!,
                          swapTmpRes.rawBytes!,
                          expectedPreSwapIdentity,
                        );
                      const matchesMySwap =
                        expectedIdentity !== undefined &&
                        matchesFileIdentity(
                          swapTmpRes.bigintStat!,
                          swapTmpRes.rawBytes!,
                          expectedIdentity,
                        );
                      if (matchesPreSwap || matchesMySwap) {
                        try {
                          fs.unlinkSync(swapTmpPath);
                        } catch (err) {
                          if ((err as NodeJS.ErrnoException | undefined)?.code !== "ENOENT") {
                            throw err;
                          }
                        }
                      } else {
                        swapConflictedWithExternal = true;
                        const prevTitleStr =
                          typeof rec.prevManifestTitle === "string"
                            ? rec.prevManifestTitle
                            : manifest.title;
                        let snapRaw: string | null = null;
                        if (typeof rec.preSwapManifestSnapRelPath === "string") {
                          const preSnapRes = this.readMeetingFileByFd(
                            meetingId,
                            null,
                            rec.preSwapManifestSnapRelPath,
                            { maxReadBytes: MAX_SAFE_MANIFEST_BYTES, allowTruncate: false },
                          );
                          if (
                            preSnapRes.kind === "ok" &&
                            (expectedPreSwapIdentity === undefined ||
                              sha256Hex(preSnapRes.rawBytes!) ===
                                expectedPreSwapIdentity.sha256.toLowerCase())
                          ) {
                            snapRaw = preSnapRes.content;
                          }
                        }
                        if (
                          snapRaw === null &&
                          matchesExpectedManifest &&
                          typeof rec.prevManifestTitle === "string"
                        ) {
                          snapRaw = this.preparePatchedManifestText(
                            manifestRawText,
                            { title: rec.prevManifestTitle },
                            meetingId,
                          );
                        }
                        if (snapRaw === null) {
                          throw new Error(
                            `恢复清单并发备份失败（缺少交换前基线快照），已保留事务日志与备份于 ${swapTmpPath}: ${meetingId}`,
                          );
                        }
                        runMergeMustResolve({
                          backupPath: swapTmpPath,
                          snapshotRaw: snapRaw,
                          nextTitle: typeof rec.targetTitle === "string" ? rec.targetTitle : "",
                          fallbackPrevTitle: prevTitleStr,
                          attemptedTitleToken:
                            typeof rec.targetTitle === "string"
                              ? JSON.stringify(rec.targetTitle)
                              : null,
                          detail: "crash_between_swap_and_verify",
                        });
                      }
                    }
                  }
                }

                if (swapConflictedWithExternal) {
                  abortCurrentWal();
                } else {
                  const savedIdent = this.readFileIdentityByFdUnlocked(
                    meetingId,
                    savedSubdir,
                    savedBase,
                  );
                  if (savedIdent.kind === "invalid") {
                    throw new Error(`恢复暂存写入时拒绝覆盖非普通文件: ${rec.savedRelPath}`);
                  }
                  const stagedIdent = this.readFileIdentityByFdUnlocked(
                    meetingId,
                    savedSubdir,
                    stagedBase,
                  );
                  if (stagedIdent.kind !== "ok") {
                    throw new Error(`无法读取暂存正文用于事务恢复: ${rec.stagedTmpRelPath}`);
                  }

                  const savedMatchesStaged =
                    txMode === "title_and_body" &&
                    stagedFileIdentity !== undefined &&
                    savedIdent.kind === "ok" &&
                    matchesFileIdentityHash(
                      savedIdent.bigintStat,
                      savedIdent.sha256,
                      stagedFileIdentity,
                    );

                  if (savedMatchesStaged) {
                    const stagedHoldsPrev =
                      prevSavedIdentity?.exists === true &&
                      matchesSavedFileIdentityHash(
                        stagedIdent.bigintStat,
                        stagedIdent.sha256,
                        prevSavedIdentity,
                      );
                    if (!stagedHoldsPrev) {
                      const restoreDisplaced = this.atomicSwapStagedFileWithIdentity({
                        meetingId,
                        subdir: savedSubdir,
                        stagedBase,
                        savedBase,
                        stagedTmpPath: stagedTmpPath!,
                        savedPath: savedPath!,
                        expectedTargetStat: savedIdent.bigintStat,
                        expectedTargetSha256: savedIdent.sha256,
                        stagedStat: stagedIdent.bigintStat,
                        stagedSha256: stagedIdent.sha256,
                      });
                      if (restoreDisplaced.kind === "conflict") {
                        throw new Error(
                          `恢复被置换的外部正文失败，已保留外部正文备份于 ${stagedTmpPath}: ${meetingId}`,
                        );
                      }
                      safeRevertOwnManifestTitle();
                      abortCurrentWal();
                    } else if (manifest.title === rec.targetTitle) {
                      try {
                        fs.unlinkSync(stagedTmpPath!);
                      } catch (err) {
                        if ((err as NodeJS.ErrnoException | undefined)?.code !== "ENOENT") {
                          throw err;
                        }
                      }
                      applyCommittedLease();
                      cleanupTxAndPreSwapSnap();
                    } else {
                      const undoBodyCas = this.atomicSwapStagedFileWithIdentity({
                        meetingId,
                        subdir: savedSubdir,
                        stagedBase,
                        savedBase,
                        stagedTmpPath: stagedTmpPath!,
                        savedPath: savedPath!,
                        expectedTargetStat: savedIdent.bigintStat,
                        expectedTargetSha256: savedIdent.sha256,
                        stagedStat: stagedIdent.bigintStat,
                        stagedSha256: stagedIdent.sha256,
                      });
                      if (
                        undoBodyCas.kind === "conflict" &&
                        !undoBodyCas.preservedLatest &&
                        undoBodyCas.backupPath
                      ) {
                        throw new Error(
                          `恢复正文时发生外部冲突且回退失败，外部正文已备份于 ${undoBodyCas.backupPath}: ${meetingId}`,
                        );
                      }
                      abortCurrentWal();
                    }
                  } else {
                    const savedMatchesPrev = (() => {
                      if (!prevSavedIdentity || !savedPath) {
                        return false;
                      }
                      if (!prevSavedIdentity.exists) {
                        return savedIdent.kind === "missing";
                      }
                      if (savedIdent.kind !== "ok") {
                        return false;
                      }
                      return matchesSavedFileIdentityHash(
                        savedIdent.bigintStat,
                        savedIdent.sha256,
                        prevSavedIdentity,
                      );
                    })();

                    const stagedMatchesExpected =
                      stagedFileIdentity === undefined ||
                      matchesFileIdentityHash(
                        stagedIdent.bigintStat,
                        stagedIdent.sha256,
                        stagedFileIdentity,
                      );

                    const shouldRollForward =
                      txMode === "title_and_body" &&
                      manifest.title === rec.targetTitle &&
                      expectedIdentity !== undefined &&
                      matchesExpectedManifest &&
                      prevSavedIdentity !== undefined &&
                      savedMatchesPrev &&
                      stagedMatchesExpected;

                    if (!shouldRollForward) {
                      if (
                        txMode === "title_and_body" &&
                        manifest.title === rec.targetTitle &&
                        matchesExpectedManifest &&
                        (!savedMatchesPrev || !stagedMatchesExpected)
                      ) {
                        safeRevertOwnManifestTitle();
                      }
                      abortCurrentWal();
                    } else {
                      const stagedIdentityRec =
                        stagedFileIdentity ??
                        buildFileIdentityFromHash(stagedIdent.bigintStat, stagedIdent.sha256);
                      if (stagedFileIdentity === undefined) {
                        curTxState.stagedFileIdentity = stagedIdentityRec;
                        this.atomicWriteFile(txPath, JSON.stringify(curTxState));
                      }

                      let preRfLeaseContent: string | null = null;
                      let rfAppliedLeaseContent: string | null = null;
                      let touchedLeaseForRf = false;
                      if (leaseAction === "touch") {
                        this.assertSafeLeaseTarget(dir);
                        const preRfLease = this.readMeetingFileByFd(
                          meetingId,
                          null,
                          LEASE_FILE_NAME,
                          { maxReadBytes: 64 * 1024, allowTruncate: false },
                        );
                        preRfLeaseContent =
                          preRfLease.kind === "ok" ? preRfLease.content : null;
                        const rfNow = Date.now();
                        rfAppliedLeaseContent = JSON.stringify({
                          updatedAt: rfNow,
                          expiresAt: rfNow + DEFAULT_LEASE_TTL_MS,
                        });
                        curTxState.appliedLeaseContent = rfAppliedLeaseContent;
                        this.atomicWriteFile(txPath, JSON.stringify(curTxState));
                        this.touchTranscriptionLeaseUnlocked(
                          meetingId,
                          dir,
                          DEFAULT_LEASE_TTL_MS,
                          rfAppliedLeaseContent,
                        );
                        touchedLeaseForRf = true;
                      }

                      const undoRfLease = () => {
                        if (!touchedLeaseForRf) return;
                        this.rollbackLeaseSafelyUnlocked(meetingId, dir, {
                          leaseAction: "touch",
                          prevLeaseContent: preRfLeaseContent,
                          appliedLeaseContent: rfAppliedLeaseContent,
                        });
                      };

                      const preBodyMan = this.readManifestWithRaw(meetingId);
                      if (
                        !matchesFileIdentity(
                          preBodyMan.bigintStat,
                          preBodyMan.rawBytes,
                          expectedIdentity!,
                        )
                      ) {
                        undoRfLease();
                        abortCurrentWal();
                      } else {
                        let bodyCommittedOnRf = false;
                        if (!prevSavedIdentity!.exists) {
                          if (curTxState.rfMovedExcl !== true) {
                            curTxState.rfMovedExcl = true;
                            this.atomicWriteFile(txPath, JSON.stringify(curTxState));
                          }
                          let exclEexist = false;
                          try {
                            safeOpenat.renamex_excl(stagedTmpPath!, savedPath!);
                          } catch (exclErr) {
                            if ((exclErr as NodeJS.ErrnoException | undefined)?.code === "EEXIST") {
                              exclEexist = true;
                            } else {
                              undoRfLease();
                              throw exclErr;
                            }
                          }
                          if (exclEexist) {
                            undoRfLease();
                            safeRevertOwnManifestTitle();
                            abortCurrentWal();
                          } else {
                            const placedAfterExcl = this.readFileIdentityByFdUnlocked(
                              meetingId,
                              savedSubdir,
                              savedBase,
                            );
                            if (
                              placedAfterExcl.kind !== "ok" ||
                              !matchesFileIdentityHash(
                                placedAfterExcl.bigintStat,
                                placedAfterExcl.sha256,
                                stagedIdentityRec,
                              )
                            ) {
                              if (
                                placedAfterExcl.kind === "ok" &&
                                placedAfterExcl.bigintStat.ino.toString() === stagedIdentityRec.ino
                              ) {
                                try {
                                  fs.unlinkSync(savedPath!);
                                } catch {
                                  // ignore
                                }
                              }
                              undoRfLease();
                              safeRevertOwnManifestTitle();
                              abortCurrentWal();
                            } else {
                              let postBodyMan: ReturnType<MeetingStore["readManifestWithRaw"]>;
                              try {
                                postBodyMan = this.readManifestWithRaw(meetingId);
                              } catch (postManErr) {
                                try {
                                  const placed = this.readFileIdentityByFdUnlocked(
                                    meetingId,
                                    savedSubdir,
                                    savedBase,
                                  );
                                  if (
                                    placed.kind === "ok" &&
                                    matchesFileIdentityHash(
                                      placed.bigintStat,
                                      placed.sha256,
                                      stagedIdentityRec,
                                    )
                                  ) {
                                    safeOpenat.renamex_excl(savedPath!, stagedTmpPath!);
                                  }
                                } catch {
                                  // Leave rfMovedExcl in txPath if move back fails
                                }
                                try {
                                  undoRfLease();
                                } catch {
                                  // Best-effort lease undo
                                }
                                throw postManErr;
                              }
                              if (postBodyMan.manifest.title !== rec.targetTitle) {
                                const placedIdent = this.readFileIdentityByFdUnlocked(
                                  meetingId,
                                  savedSubdir,
                                  savedBase,
                                );
                                if (
                                  placedIdent.kind === "ok" &&
                                  matchesFileIdentityHash(
                                    placedIdent.bigintStat,
                                    placedIdent.sha256,
                                    stagedIdentityRec,
                                  )
                                ) {
                                  try {
                                    fs.unlinkSync(savedPath!);
                                  } catch {
                                    // ignore
                                  }
                                }
                                undoRfLease();
                                abortCurrentWal();
                              } else {
                                bodyCommittedOnRf = true;
                              }
                            }
                          }
                        } else if (savedIdent.kind === "ok") {
                          const bodyCas = this.atomicSwapStagedFileWithIdentity({
                            meetingId,
                            subdir: savedSubdir,
                            stagedBase,
                            savedBase,
                            stagedTmpPath: stagedTmpPath!,
                            savedPath: savedPath!,
                            expectedTargetStat: savedIdent.bigintStat,
                            expectedTargetSha256: savedIdent.sha256,
                            stagedStat: stagedIdent.bigintStat,
                            stagedSha256: stagedIdent.sha256,
                          });
                          if (bodyCas.kind === "conflict") {
                            if (!bodyCas.preservedLatest && bodyCas.backupPath) {
                              throw new Error(
                                `恢复正文时发生外部冲突且回退失败，外部正文已备份于 ${bodyCas.backupPath}: ${meetingId}`,
                              );
                            }
                            undoRfLease();
                            safeRevertOwnManifestTitle();
                            abortCurrentWal();
                          } else {
                            const placedAfterSwap = this.readFileIdentityByFdUnlocked(
                              meetingId,
                              savedSubdir,
                              savedBase,
                            );
                            if (
                              placedAfterSwap.kind !== "ok" ||
                              !matchesFileIdentityHash(
                                placedAfterSwap.bigintStat,
                                placedAfterSwap.sha256,
                                stagedIdentityRec,
                              )
                            ) {
                              if (placedAfterSwap.kind === "ok") {
                                try {
                                  this.atomicSwapStagedFileWithIdentity({
                                    meetingId,
                                    subdir: savedSubdir,
                                    stagedBase,
                                    savedBase,
                                    stagedTmpPath: stagedTmpPath!,
                                    savedPath: savedPath!,
                                    expectedTargetStat: placedAfterSwap.bigintStat,
                                    expectedTargetSha256: placedAfterSwap.sha256,
                                    stagedStat: savedIdent.bigintStat,
                                    stagedSha256: savedIdent.sha256,
                                  });
                                } catch {
                                  // Best-effort restore
                                }
                              }
                              undoRfLease();
                              safeRevertOwnManifestTitle();
                              abortCurrentWal();
                            } else {
                              let postBodyMan: ReturnType<MeetingStore["readManifestWithRaw"]>;
                              try {
                                postBodyMan = this.readManifestWithRaw(meetingId);
                              } catch (postManErr) {
                                try {
                                  this.atomicSwapStagedFileWithIdentity({
                                    meetingId,
                                    subdir: savedSubdir,
                                    stagedBase,
                                    savedBase,
                                    stagedTmpPath: stagedTmpPath!,
                                    savedPath: savedPath!,
                                    expectedTargetStat: stagedIdent.bigintStat,
                                    expectedTargetSha256: stagedIdent.sha256,
                                    stagedStat: savedIdent.bigintStat,
                                    stagedSha256: savedIdent.sha256,
                                  });
                                } catch {
                                  // Best-effort body restore before propagating EIO
                                }
                                try {
                                  undoRfLease();
                                } catch {
                                  // Best-effort lease undo
                                }
                                throw postManErr;
                              }
                              if (postBodyMan.manifest.title !== rec.targetTitle) {
                                const undoBodyCas = this.atomicSwapStagedFileWithIdentity({
                                  meetingId,
                                  subdir: savedSubdir,
                                  stagedBase,
                                  savedBase,
                                  stagedTmpPath: stagedTmpPath!,
                                  savedPath: savedPath!,
                                  expectedTargetStat: stagedIdent.bigintStat,
                                  expectedTargetSha256: stagedIdent.sha256,
                                  stagedStat: savedIdent.bigintStat,
                                  stagedSha256: savedIdent.sha256,
                                });
                                if (
                                  undoBodyCas.kind === "conflict" &&
                                  !undoBodyCas.preservedLatest &&
                                  undoBodyCas.backupPath
                                ) {
                                  throw new Error(
                                    `恢复正文时发生外部冲突且回退失败，外部正文已备份于 ${undoBodyCas.backupPath}: ${meetingId}`,
                                  );
                                }
                                undoRfLease();
                                abortCurrentWal();
                              } else {
                                try {
                                  fs.unlinkSync(stagedTmpPath!);
                                } catch (err) {
                                  if (
                                    (err as NodeJS.ErrnoException | undefined)?.code !== "ENOENT"
                                  ) {
                                    throw err;
                                  }
                                }
                                bodyCommittedOnRf = true;
                              }
                            }
                          }
                        }

                        if (bodyCommittedOnRf) {
                          if (leaseAction === "clear") {
                            this.clearMatchingLeaseUnlocked(
                              meetingId,
                              dir,
                              expectedPrevLeaseContent,
                              { restoreExpiredIfBlocked: true },
                            );
                          }
                          cleanupTxAndPreSwapSnap();
                        }
                      }
                    }
                  }
                }
              } else {
                if (
                  rec.rfMovedExcl === true &&
                  txMode === "title_and_body" &&
                  manifest.title !== rec.targetTitle &&
                  stagedFileIdentity !== undefined &&
                  savedPath
                ) {
                  const placedIdent = this.readFileIdentityByFdUnlocked(
                    meetingId,
                    savedSubdir,
                    savedBase,
                  );
                  if (
                    placedIdent.kind === "ok" &&
                    matchesFileIdentityHash(
                      placedIdent.bigintStat,
                      placedIdent.sha256,
                      stagedFileIdentity,
                    )
                  ) {
                    try {
                      fs.unlinkSync(savedPath);
                    } catch (err) {
                      if ((err as NodeJS.ErrnoException | undefined)?.code !== "ENOENT") {
                        throw err;
                      }
                    }
                  }
                  abortCurrentWal();
                } else {
                  applyCommittedLease();
                  cleanupTxAndPreSwapSnap();
                }
              }
            }
          }
        }
      }
    }

    if (!lstatIfExists(txPath)) {
      let dirEntries: fs.Dirent[] = [];
      try {
        dirEntries = fs.readdirSync(dir, { withFileTypes: true });
      } catch {
        dirEntries = [];
      }
      for (const ent of dirEntries) {
        if (!MANIFEST_SNAP_FILE_RE.test(ent.name)) continue;
        const straySnapPath = path.join(dir, ent.name);
        const strayLst = lstatIfExists(straySnapPath);
        if (strayLst && !strayLst.isSymbolicLink() && strayLst.isFile()) {
          try {
            fs.unlinkSync(straySnapPath);
          } catch (err) {
            if ((err as NodeJS.ErrnoException | undefined)?.code !== "ENOENT") {
              throw err;
            }
          }
        }
      }
    }

    this.recoverPendingCleanupRevertMarkersUnlocked(meetingId, dir);
  }

  private maybeRecoverPendingSaveTx(meetingId: string): void {
    const dir = this.resolveMeetingDir(meetingId);
    if (
      !lstatIfExists(path.join(dir, SAVE_TX_FILE_NAME)) &&
      !this.hasPendingCleanupRevertMarker(dir) &&
      !this.hasPendingLeaseBackupFile(dir)
    ) {
      return;
    }
    this.withMeetingWriteLock(meetingId, () => {
      const lockedDir = this.resolveMeetingDir(meetingId);
      this.recoverPendingSaveTxUnlocked(meetingId, lockedDir);
    });
  }

  readManifest(meetingId: string): MeetingManifest {
    this.maybeRecoverPendingSaveTx(meetingId);
    return this.readManifestWithRaw(meetingId).manifest;
  }

  toViewManifest(manifest: MeetingManifest): MeetingViewManifest {
    return {
      schemaVersion: manifest.schemaVersion,
      id: manifest.id,
      title: manifest.title,
      mode: manifest.mode,
      appTarget: manifest.appTarget,
      status: manifest.status,
      createdAt: manifest.createdAt,
      ...(manifest.endedAt !== undefined ? { endedAt: manifest.endedAt } : {}),
      totalDurationSec: manifest.totalDurationSec,
      gaps: manifest.gaps,
      audioCleaned: manifest.audioCleaned,
      ...(manifest.failedChunkCount !== undefined
        ? { failedChunkCount: manifest.failedChunkCount }
        : {}),
      ...(manifest.lastError !== undefined ? { lastError: manifest.lastError } : {}),
    };
  }

  private createLeaseExclUnlocked(dir: string, content: string): void {
    const lockPath = path.join(dir, LEASE_FILE_NAME);
    const tmp = this.writeStagingTempFile(dir, LEASE_FILE_NAME, content);
    try {
      safeOpenat.renamex_excl(tmp, lockPath);
    } catch (err) {
      try {
        fs.unlinkSync(tmp);
      } catch {
        // ignore
      }
      if ((err as NodeJS.ErrnoException | undefined)?.code !== "EEXIST") {
        throw err;
      }
    }
  }

  private rollbackLeaseSafelyUnlocked(
    meetingId: string,
    dir: string,
    info: {
      leaseAction: "none" | "touch" | "clear";
      prevLeaseContent: string | null | undefined;
      appliedLeaseContent?: string | null;
    },
  ): void {
    if (info.leaseAction === "none") return;
    this.assertSafeLeaseTarget(dir);
    const lockPath = path.join(dir, LEASE_FILE_NAME);
    const curLease = this.readMeetingFileByFd(meetingId, null, LEASE_FILE_NAME, {
      maxReadBytes: 64 * 1024,
      allowTruncate: false,
    });
    if (curLease.kind === "invalid" || curLease.kind === "too_large") {
      throw new Error(`拒绝清理异常转写锁目标: ${LEASE_FILE_NAME}`);
    }
    const prevExp = parseLeaseExpiresAt(info.prevLeaseContent);

    if (info.leaseAction === "clear") {
      if (typeof info.prevLeaseContent !== "string" || prevExp === null || prevExp <= Date.now()) {
        return;
      }
      for (let attempt = 0; attempt < 5; attempt += 1) {
        const latestLease =
          attempt === 0
            ? curLease
            : this.readMeetingFileByFd(meetingId, null, LEASE_FILE_NAME, {
                maxReadBytes: 64 * 1024,
                allowTruncate: false,
              });
        if (latestLease.kind === "invalid" || latestLease.kind === "too_large") {
          throw new Error(`拒绝清理异常转写锁目标: ${LEASE_FILE_NAME}`);
        }
        if (latestLease.kind === "missing") {
          this.createLeaseExclUnlocked(dir, info.prevLeaseContent);
        } else {
          const curExp = parseLeaseExpiresAt(latestLease.content);
          if (curExp !== null && curExp >= prevExp) {
            return;
          }
          const cas = this.atomicCompareAndSwapFile(
            lockPath,
            info.prevLeaseContent,
            latestLease.bigintStat!,
            latestLease.rawBytes!,
          );
          if (cas.kind === "conflict" && !cas.preservedLatest) {
            this.handleLeaseCasConflictUnlocked(meetingId, dir, cas);
          }
        }
        const verified = this.readMeetingFileByFd(meetingId, null, LEASE_FILE_NAME, {
          maxReadBytes: 64 * 1024,
          allowTruncate: false,
        });
        const verifiedExp = verified.kind === "ok" ? parseLeaseExpiresAt(verified.content) : null;
        if (verifiedExp !== null && verifiedExp >= prevExp) {
          return;
        }
      }
      throw new Error(`恢复转写锁失败，未能还原至少 ${prevExp} 的租约有效期: ${meetingId}`);
    }

    // leaseAction === "touch"
    if (curLease.kind === "missing") {
      if (typeof info.prevLeaseContent === "string" && prevExp !== null && prevExp > Date.now()) {
        this.createLeaseExclUnlocked(dir, info.prevLeaseContent);
      }
      return;
    }
    if (typeof info.appliedLeaseContent === "string") {
      if (curLease.content !== info.appliedLeaseContent) {
        return;
      }
    } else {
      const curExp = parseLeaseExpiresAt(curLease.content);
      if (curExp !== null && curExp > Date.now() && (prevExp === null || curExp > prevExp)) {
        return;
      }
    }
    const target =
      typeof info.prevLeaseContent === "string" ? info.prevLeaseContent : EXPIRED_LEASE_JSON;
    const cas = this.atomicCompareAndSwapFile(
      lockPath,
      target,
      curLease.bigintStat!,
      curLease.rawBytes!,
    );
    this.handleLeaseCasConflictUnlocked(meetingId, dir, cas);
  }

  private touchTranscriptionLeaseUnlocked(
    meetingId: string,
    dir: string,
    ttlMs = DEFAULT_LEASE_TTL_MS,
    prebuiltContent?: string,
  ): void {
    const opened = this.openMeetingFileByComponents(meetingId, null, "manifest.json");
    if (opened.kind === "missing") return;
    if (opened.kind !== "ok") {
      throw new Error(`manifest.json 非法（符号链接、管道或非普通文件）: ${meetingId}`);
    }
    fs.closeSync(opened.fd);
    const now = Date.now();
    this.atomicWriteFile(
      path.join(dir, LEASE_FILE_NAME),
      prebuiltContent ?? JSON.stringify({ updatedAt: now, expiresAt: now + ttlMs }),
    );
  }

  private clearTranscriptionLeaseUnlocked(meetingId: string, dir: string): void {
    this.assertSafeLeaseTarget(dir);
    const lockPath = path.join(dir, LEASE_FILE_NAME);
    const curLease = this.readMeetingFileByFd(meetingId, null, LEASE_FILE_NAME, {
      maxReadBytes: 64 * 1024,
      allowTruncate: false,
    });
    if (curLease.kind === "missing") return;
    if (curLease.kind !== "ok") {
      throw new Error(`拒绝清理异常转写锁目标: ${LEASE_FILE_NAME}`);
    }
    if (curLease.content === EXPIRED_LEASE_JSON) {
      return;
    }
    const cas = this.atomicCompareAndSwapFile(
      lockPath,
      EXPIRED_LEASE_JSON,
      curLease.bigintStat!,
      curLease.rawBytes!,
    );
    if (cas.kind === "conflict" && !cas.preservedLatest) {
      this.handleLeaseCasConflictUnlocked(meetingId, dir, cas);
    }
  }

  private isTranscribingUnlocked(meetingId: string, dir: string): boolean {
    const lockPath = path.join(dir, LEASE_FILE_NAME);
    for (let attempt = 0; attempt < 3; attempt += 1) {
      const res = this.readMeetingFileByFd(meetingId, null, LEASE_FILE_NAME, {
        maxReadBytes: 64 * 1024,
        allowTruncate: false,
      });
      if (res.kind === "missing") {
        if (this.hasActiveLeaseBackupUnlocked(meetingId, dir)) {
          return true;
        }
        if (!lstatIfExistsBigInt(lockPath)) {
          if (this.hasActiveLeaseBackupUnlocked(meetingId, dir)) {
            return true;
          }
          return false;
        }
        continue;
      }
      if (res.kind === "invalid" || res.kind === "too_large") {
        throw new Error(`转写锁文件异常（符号链接、管道或非普通文件），已拒绝变更操作: ${meetingId}`);
      }

      let data: unknown;
      try {
        data = JSON.parse(res.content) as unknown;
      } catch {
        throw new Error(`转写锁文件格式损坏，已拒绝变更操作: ${meetingId}`);
      }
      if (!isPlainRecord(data) || typeof data.expiresAt !== "number" || !Number.isFinite(data.expiresAt)) {
        throw new Error(`转写锁文件缺少有效 expiresAt，已拒绝变更操作: ${meetingId}`);
      }
      if (Date.now() < data.expiresAt) {
        return true;
      }

      if (this.hasActiveLeaseBackupUnlocked(meetingId, dir)) {
        return true;
      }

      const lstAfter = lstatIfExistsBigInt(lockPath);
      if (!lstAfter) {
        if (this.hasActiveLeaseBackupUnlocked(meetingId, dir)) {
          return true;
        }
        return false;
      }
      if (lstAfter.isSymbolicLink() || !lstAfter.isFile()) {
        throw new Error(`转写锁文件异常（符号链接、管道或非普通文件），已拒绝变更操作: ${meetingId}`);
      }
      if (res.bigintStat && sameBigIntFileIdentity(lstAfter, res.bigintStat) && res.rawBytes) {
        const curBytes = readRegularFileBytesIfExists(lockPath, 64 * 1024);
        const lstFinal = lstatIfExistsBigInt(lockPath);
        if (
          curBytes !== null &&
          curBytes.equals(res.rawBytes) &&
          lstFinal !== null &&
          !lstFinal.isSymbolicLink() &&
          lstFinal.isFile() &&
          sameBigIntFileIdentity(lstFinal, res.bigintStat)
        ) {
          if (this.hasActiveLeaseBackupUnlocked(meetingId, dir)) {
            return true;
          }
          return false;
        }
      }
    }
    return true;
  }

  private recoverPendingSaveTxIfManifestExistsUnlocked(meetingId: string, dir: string): void {
    if (
      !lstatIfExists(path.join(dir, SAVE_TX_FILE_NAME)) &&
      !this.hasPendingCleanupRevertMarker(dir) &&
      !this.hasPendingLeaseBackupFile(dir)
    ) {
      return;
    }
    const opened = this.openMeetingFileByComponents(meetingId, null, "manifest.json");
    if (opened.kind === "missing") return;
    if (opened.kind === "ok") {
      fs.closeSync(opened.fd);
    }
    this.recoverPendingSaveTxUnlocked(meetingId, dir);
  }

  touchTranscriptionLease(meetingId: string, ttlMs = DEFAULT_LEASE_TTL_MS): void {
    this.withMeetingWriteLock(meetingId, () => {
      const dir = this.resolveMeetingDir(meetingId);
      this.recoverPendingSaveTxIfManifestExistsUnlocked(meetingId, dir);
      this.touchTranscriptionLeaseUnlocked(meetingId, dir, ttlMs);
    });
  }

  clearTranscriptionLease(meetingId: string): void {
    this.withMeetingWriteLock(meetingId, () => {
      const dir = this.resolveMeetingDir(meetingId);
      this.recoverPendingSaveTxIfManifestExistsUnlocked(meetingId, dir);
      this.clearTranscriptionLeaseUnlocked(meetingId, dir);
    });
  }

  isTranscribing(meetingId: string): boolean {
    const dir = this.resolveMeetingDir(meetingId);
    return this.isTranscribingUnlocked(meetingId, dir);
  }

  hasMissingChunks(meetingId: string): boolean {
    const dir = this.resolveMeetingDir(meetingId);
    const manifest = this.readManifest(meetingId);
    const { missingChunkIds } = this.getTranscriptChunkStatus(meetingId, dir, manifest.chunks);
    return missingChunkIds.length > 0;
  }

  private getTranscriptChunkStatus(
    meetingId: string,
    dir: string,
    chunks: ChunkRecord[],
  ): {
    transcribedChunkIds: string[];
    missingChunkIds: string[];
    partialTranscriptPaths: Record<string, string>;
  } {
    const safeTranscripts = this.assertSafeSubdir(dir, "transcripts");
    const transcribedChunkIds: string[] = [];
    const missingChunkIds: string[] = [];
    const partialTranscriptPaths: Record<string, string> = {};

    for (const c of chunks) {
      const id = this.validateChunkId(c.id);
      if (safeTranscripts) {
        const fileName = `${id}.md`;
        const st = this.statMeetingFileByFd(meetingId, "transcripts", fileName);
        if (st && st.size > 0) {
          transcribedChunkIds.push(id);
          partialTranscriptPaths[id] = path.join(safeTranscripts, fileName);
          continue;
        }
      }
      missingChunkIds.push(id);
    }

    return { transcribedChunkIds, missingChunkIds, partialTranscriptPaths };
  }

  private resolveChunkInfo(
    meetingId: string,
    dir: string,
    c: ChunkRecord,
    transcribedSet: Set<string>,
  ): MeetingChunkInfo {
    const checkedMix = this.resolveSafeMeetingSubpath(meetingId, dir, "chunks", c.audioPath, CHUNK_REL_PATH_RE);
    const checkedMic = c.micPath
      ? this.resolveSafeMeetingSubpath(meetingId, dir, "chunks", c.micPath, CHUNK_REL_PATH_RE)
      : undefined;
    const checkedRemote = c.remotePath
      ? this.resolveSafeMeetingSubpath(meetingId, dir, "chunks", c.remotePath, CHUNK_REL_PATH_RE)
      : undefined;
    const checkedTimeline = c.timelinePath
      ? this.resolveSafeMeetingSubpath(meetingId, dir, "timelines", c.timelinePath, TIMELINE_REL_PATH_RE)
      : undefined;

    return {
      index: c.index,
      id: c.id,
      audioPath: c.audioPath,
      ...(c.micPath !== undefined ? { micPath: c.micPath } : {}),
      ...(c.remotePath !== undefined ? { remotePath: c.remotePath } : {}),
      ...(c.timelinePath !== undefined ? { timelinePath: c.timelinePath } : {}),
      audioRangeSec: [c.audioRangeSec[0], c.audioRangeSec[1]],
      responsibleRangeSec: [c.responsibleRangeSec[0], c.responsibleRangeSec[1]],
      durationSec: c.durationSec,
      byteSize: c.byteSize,
      committedAt: c.committedAt,
      absoluteAudioPath: checkedMix.absPath,
      fileExists: checkedMix.exists,
      ...(checkedMic ? { absoluteMicPath: checkedMic.absPath, micFileExists: checkedMic.exists } : {}),
      ...(checkedRemote ? { absoluteRemotePath: checkedRemote.absPath, remoteFileExists: checkedRemote.exists } : {}),
      ...(checkedTimeline
        ? { absoluteTimelinePath: checkedTimeline.absPath, timelineFileExists: checkedTimeline.exists }
        : {}),
      transcribed: transcribedSet.has(c.id),
    };
  }

  getMeetingForModel(
    meetingId: string,
    options: GetMeetingForModelOptions = {},
  ): MeetingForModel {
    if (options.acquireLeaseIfNeeded) {
      return this.withMeetingWriteLock(meetingId, () => {
        this.recoverPendingSaveTxUnlocked(meetingId, this.resolveMeetingDir(meetingId));
        return this.readMeetingForModelLocked(meetingId, options);
      });
    }
    this.maybeRecoverPendingSaveTx(meetingId);
    return this.readMeetingForModelLocked(meetingId, options);
  }

  private readMeetingForModelLocked(
    meetingId: string,
    options: GetMeetingForModelOptions = {},
  ): MeetingForModel {
    const dir = this.resolveMeetingDir(meetingId);
    const manifest = this.readManifestWithRaw(meetingId).manifest;
    const { transcribedChunkIds, missingChunkIds, partialTranscriptPaths } =
      this.getTranscriptChunkStatus(meetingId, dir, manifest.chunks);

    const transcribedSet = new Set(transcribedChunkIds);
    const safeOffset = Math.min(manifest.chunks.length, Math.max(0, Math.floor(options.chunkOffset ?? 0)));
    const indexedCandidates: Array<{ manifestPos: number; chunk: ChunkRecord }> = [];
    for (let i = safeOffset; i < manifest.chunks.length; i += 1) {
      const c = manifest.chunks[i];
      if (options.onlyMissing && transcribedSet.has(c.id)) {
        continue;
      }
      indexedCandidates.push({ manifestPos: i, chunk: c });
    }

    const requestedLimit =
      options.chunkLimit !== undefined
        ? Math.max(1, Math.min(500, Math.floor(options.chunkLimit)))
        : indexedCandidates.length;
    const requestedEntries = indexedCandidates.slice(0, requestedLimit);
    const resolvedSlice = requestedEntries.map((entry) =>
      this.resolveChunkInfo(meetingId, dir, entry.chunk, transcribedSet),
    );

    const transcriptPath = path.join(dir, "transcript.md");
    const notesPath = path.join(dir, "notes.md");
    const transcriptStat = this.statMeetingFileByFd(meetingId, null, "transcript.md");
    const notesStat = this.statMeetingFileByFd(meetingId, null, "notes.md");
    const hasFullTranscript = Boolean(transcriptStat && transcriptStat.size > 0);
    const hasNotes = Boolean(notesStat && notesStat.size > 0);

    const maxEnvelopeBytes = options.maxEnvelopeBytes ?? DEFAULT_MODEL_ENVELOPE_BUDGET_BYTES;
    const { hostTimeOriginNs: _omittedHostOrigin, ...manifestWithoutHostOrigin } = manifest;

    let hasPendingStaging = false;
    try {
      const ownedStaging = this.scanOwnedStagingFiles(dir);
      hasPendingStaging =
        ownedStaging.stagedFiles.length > 0 || ownedStaging.unreadableStagingDirs.length > 0;
    } catch {
      hasPendingStaging = true;
    }
    const hasLiveCleanable = this.collectOwnedLiveTargets(dir, manifest, { strict: false }).length > 0;

    const buildPayload = (
      count: number,
      scopePartials: boolean,
    ): MeetingForModel => {
      const pageRawChunks = requestedEntries.slice(0, count).map((e) => e.chunk);
      const pageChunks = resolvedSlice.slice(0, count);
      const hasMoreChunks = count < indexedCandidates.length;
      const nextChunkOffset = hasMoreChunks ? indexedCandidates[count].manifestPos : null;
      const chunksTruncated = count < requestedEntries.length || hasMoreChunks || safeOffset > 0;

      let partialMap: Record<string, string> = partialTranscriptPaths;
      if (scopePartials || chunksTruncated) {
        partialMap = {};
        for (const c of pageChunks) {
          if (partialTranscriptPaths[c.id]) {
            partialMap[c.id] = partialTranscriptPaths[c.id];
          }
        }
      }

      const manifestPage: MeetingModelManifest = {
        ...manifestWithoutHostOrigin,
        audioCleaned: Boolean(manifestWithoutHostOrigin.audioCleaned) && !hasPendingStaging && !hasLiveCleanable,
        chunks: pageRawChunks,
      };

      return {
        manifest: manifestPage,
        meetingDir: dir,
        chunks: pageChunks,
        totalChunks: manifest.chunks.length,
        chunkOffset: safeOffset,
        chunkLimit: pageChunks.length,
        hasMoreChunks,
        nextChunkOffset,
        chunksTruncated,
        transcribedChunkIds,
        missingChunkIds,
        hasFullTranscript,
        hasNotes,
        transcriptPath,
        notesPath,
        partialTranscriptPaths: partialMap,
      };
    };

    let payload: MeetingForModel;
    const fullCandidate = buildPayload(resolvedSlice.length, false);
    if (
      resolvedSlice.length === 0 ||
      measureModelEnvelopeBytes(fullCandidate as unknown as Record<string, unknown>) <= maxEnvelopeBytes
    ) {
      payload = fullCandidate;
    } else {
      let lo = 1;
      let hi = resolvedSlice.length;
      let bestCount = 0;
      while (lo <= hi) {
        const mid = Math.floor((lo + hi) / 2);
        const probe = buildPayload(mid, true);
        if (measureModelEnvelopeBytes(probe as unknown as Record<string, unknown>) <= maxEnvelopeBytes) {
          bestCount = mid;
          lo = mid + 1;
        } else {
          hi = mid - 1;
        }
      }

      if (bestCount === 0) {
        throw new Error(
          "会议元数据过大导致单页无法容纳任何切片（超过 1 MiB 安全上限），请先缩短过长的会议标题或直接读取磁盘 manifest.json",
        );
      }

      payload = buildPayload(bestCount, true);
    }

    options.beforeLease?.(payload);

    if (
      options.acquireLeaseIfNeeded &&
      missingChunkIds.length > 0 &&
      manifest.status !== "recording" &&
      manifest.status !== "finalizing"
    ) {
      let hasLiveMissingAudio = false;
      for (const c of manifest.chunks) {
        if (transcribedSet.has(c.id)) continue;
        const trackRels = [c.audioPath, c.micPath, c.remotePath].filter(
          (p): p is string => typeof p === "string" && p.length > 0,
        );
        for (const rel of trackRels) {
          try {
            const checked = this.resolveSafeMeetingSubpath(
              meetingId,
              dir,
              "chunks",
              rel,
              CHUNK_REL_PATH_RE,
            );
            if (checked.exists) {
              hasLiveMissingAudio = true;
              break;
            }
          } catch {
            // ignore invalid subpath during lease check
          }
        }
        if (hasLiveMissingAudio) break;
      }
      if (hasLiveMissingAudio) {
        this.touchTranscriptionLeaseUnlocked(meetingId, dir);
      }
    }

    return payload;
  }

  private computeSpeakerStats(
    meetingId: string,
    dir: string,
    chunks: ChunkRecord[],
  ): SpeakerStats | undefined {
    let meSec = 0;
    let remoteSec = 0;
    let bothSec = 0;
    let timelineChunkCount = 0;

    for (const c of chunks) {
      if (!c.timelinePath) continue;
      try {
        const checked = this.resolveSafeMeetingSubpath(
          meetingId,
          dir,
          "timelines",
          c.timelinePath,
          TIMELINE_REL_PATH_RE,
        );
        if (!checked.exists) continue;
        const res = this.readMeetingFileByFd(meetingId, "timelines", checked.fileName, {
          maxReadBytes: 8 * 1024 * 1024,
          allowTruncate: false,
        });
        if (res.kind !== "ok") continue;
        const parsed = JSON.parse(res.content) as Partial<ChunkTimeline>;
        if (!parsed || !Array.isArray(parsed.segments)) continue;

        const [rawRespStart, rawRespEnd] = c.responsibleRangeSec;
        const respStart = Number.isFinite(rawRespStart) ? rawRespStart : 0;
        const respEnd = Number.isFinite(rawRespEnd) ? rawRespEnd : respStart;
        if (respEnd <= respStart) continue;

        timelineChunkCount += 1;
        for (const seg of parsed.segments) {
          if (
            !seg ||
            typeof seg.startSec !== "number" ||
            typeof seg.endSec !== "number" ||
            !Number.isFinite(seg.startSec) ||
            !Number.isFinite(seg.endSec)
          ) {
            continue;
          }
          const s = Math.max(seg.startSec, respStart);
          const e = Math.min(seg.endSec, respEnd);
          const dur = Math.min(86_400, Math.max(0, e - s));
          if (dur <= 0) continue;
          if (seg.speaker === "me") meSec += dur;
          else if (seg.speaker === "remote") remoteSec += dur;
          else if (seg.speaker === "both") bothSec += dur;
        }
      } catch {
        // Ignore missing/invalid timeline files so history viewing stays resilient.
      }
    }

    if (timelineChunkCount === 0) return undefined;
    const round2 = (n: number) => Math.round(n * 100) / 100;
    return {
      meSec: round2(meSec),
      remoteSec: round2(remoteSec),
      bothSec: round2(bothSec),
      timelineChunkCount,
    };
  }

  private hashMeetingFilePrefixByFd(
    meetingId: string,
    subdir: MeetingSubdir | null,
    fileName: string,
  ): string {
    const res = this.readMeetingFileByFd(meetingId, subdir, fileName, {
      maxReadBytes: REVISION_HASH_MAX_BYTES,
      allowTruncate: true,
    });
    if (res.kind !== "ok") {
      return "missing";
    }
    const digest = crypto.createHash("sha256").update(res.content, "utf8").digest("hex").slice(0, 16);
    return `${res.stat.size}:${res.stat.ino}:${res.stat.mtimeMs}:${res.stat.ctimeMs}:${digest}`;
  }

  private computeMeetingRevisionFromParts(
    meetingId: string,
    manifest: MeetingManifest,
    summary: MeetingSummary,
    speakerStats: SpeakerStats | undefined,
    transcribedChunkIds: string[],
    missingChunkIds: string[],
  ): string {
    const notesSig = this.hashMeetingFilePrefixByFd(meetingId, null, "notes.md");
    const transcriptSig = this.hashMeetingFilePrefixByFd(meetingId, null, "transcript.md");

    const partialItems: string[] = [];
    for (const id of transcribedChunkIds) {
      const st = this.statMeetingFileByFd(meetingId, "transcripts", `${id}.md`);
      if (st) {
        partialItems.push(`${id}:${st.size}:${st.ino}:${st.mtimeMs}:${st.ctimeMs}`);
      }
    }
    const partialsSig = partialItems.join("|");

    const rangesSig = manifest.chunks
      .map(
        (c) =>
          `${c.id}:${c.audioRangeSec[0]}-${c.audioRangeSec[1]}:${c.responsibleRangeSec[0]}-${c.responsibleRangeSec[1]}:${c.timelinePath ?? ""}`,
      )
      .join("|");

    const timelinesItems: string[] = [];
    for (const c of manifest.chunks) {
      if (!c.timelinePath) continue;
      const match = TIMELINE_REL_PATH_RE.exec(c.timelinePath);
      if (!match) continue;
      const st = this.statMeetingFileByFd(meetingId, "timelines", match[1]);
      timelinesItems.push(
        st ? `${c.id}:${st.size}:${st.ino}:${st.mtimeMs}:${st.ctimeMs}` : `${c.id}:missing`,
      );
    }

    return crypto
      .createHash("sha256")
      .update(
        JSON.stringify({
          summary,
          gaps: manifest.gaps,
          lastError: manifest.lastError ?? "",
          speakerStats: speakerStats ?? null,
          transcribedChunkIds,
          missingChunkIds,
          rangesSig,
          timelinesSig: timelinesItems.join("|"),
          notesSig,
          transcriptSig,
          partialsSig,
        }),
      )
      .digest("hex")
      .slice(0, 24);
  }

  getMeetingRevision(meetingId: string): { summary: MeetingSummary; revision: string } {
    const dir = this.resolveMeetingDir(meetingId);
    const manifest = this.readManifest(meetingId);
    const summary = this.toSummary(meetingId, dir, manifest);
    const { transcribedChunkIds, missingChunkIds } =
      this.getTranscriptChunkStatus(meetingId, dir, manifest.chunks);
    const speakerStats = this.computeSpeakerStats(meetingId, dir, manifest.chunks);
    const revision = this.computeMeetingRevisionFromParts(
      meetingId,
      manifest,
      summary,
      speakerStats,
      transcribedChunkIds,
      missingChunkIds,
    );
    return { summary, revision };
  }

  getMeetingView(meetingId: string): MeetingViewDetail {
    const dir = this.resolveMeetingDir(meetingId);
    const manifest = this.readManifest(meetingId);
    const summary = this.toSummary(meetingId, dir, manifest);
    const { transcribedChunkIds, missingChunkIds } =
      this.getTranscriptChunkStatus(meetingId, dir, manifest.chunks);
    const speakerStats = this.computeSpeakerStats(meetingId, dir, manifest.chunks);
    const revision = this.computeMeetingRevisionFromParts(
      meetingId,
      manifest,
      summary,
      speakerStats,
      transcribedChunkIds,
      missingChunkIds,
    );

    let transcriptPath = path.join(dir, "transcript.md");
    const notesPath = path.join(dir, "notes.md");

    let transcript = "";
    let transcriptTruncated = false;
    if (summary.hasTranscript) {
      const res = this.readMeetingFileByFd(meetingId, null, "transcript.md", {
        maxReadBytes: MAX_VIEW_FIELD_RAW_BYTES,
        allowTruncate: true,
      });
      if (res.kind === "ok") {
        const fitted = trimToJsonByteBudget(res.content, MAX_VIEW_FIELD_JSON_BYTES);
        transcript = fitted.text;
        transcriptTruncated = res.truncated || fitted.trimmed;
      }
    } else if (transcribedChunkIds.length > 0) {
      transcriptPath =
        transcribedChunkIds.length === 1
          ? path.join(dir, "transcripts", `${transcribedChunkIds[0]}.md`)
          : path.join(dir, "transcripts");
      const parts: string[] = [];
      let usedBytes = 0;
      for (const id of transcribedChunkIds) {
        const remainingBytes = Math.max(0, MAX_VIEW_FIELD_RAW_BYTES - usedBytes);
        if (remainingBytes <= 0) {
          transcriptTruncated = true;
          break;
        }
        const res = this.readMeetingFileByFd(meetingId, "transcripts", `${id}.md`, {
          maxReadBytes: remainingBytes,
          allowTruncate: true,
        });
        if (res.kind !== "ok") continue;
        const piece = `<!-- ${id} -->\n${res.content.trim()}`;
        const pieceBytes = Buffer.byteLength(piece, "utf8");
        parts.push(piece);
        usedBytes += pieceBytes + 2;
        if (res.truncated || usedBytes >= MAX_VIEW_FIELD_RAW_BYTES) {
          transcriptTruncated = true;
          break;
        }
      }
      const joined = parts.join("\n\n");
      const fitted = trimToJsonByteBudget(joined, MAX_VIEW_FIELD_JSON_BYTES);
      transcript = fitted.text;
      transcriptTruncated = transcriptTruncated || fitted.trimmed;
    }

    let notes = "";
    let notesTruncated = false;
    if (summary.hasNotes) {
      const res = this.readMeetingFileByFd(meetingId, null, "notes.md", {
        maxReadBytes: MAX_VIEW_FIELD_RAW_BYTES,
        allowTruncate: true,
      });
      if (res.kind === "ok") {
        const fitted = trimToJsonByteBudget(res.content, MAX_VIEW_FIELD_JSON_BYTES);
        notes = fitted.text;
        notesTruncated = res.truncated || fitted.trimmed;
      }
    }

    return {
      revision,
      summary,
      manifest: this.toViewManifest({
        ...manifest,
        audioCleaned: summary.audioCleaned,
      }),
      ...(speakerStats ? { speakerStats } : {}),
      transcribedChunkIds,
      missingChunkIds,
      transcript,
      notes,
      transcriptTruncated,
      notesTruncated,
      transcriptPath,
      notesPath,
    };
  }

  saveResult(params: {
    meetingId: string;
    kind: "chunk_transcript" | "full_transcript" | "notes";
    chunkId?: string;
    content: string;
    title?: string;
    manageLease?: boolean;
    beforeCommit?: (preview: SaveResultPreview) => void;
  }): SaveResultPreview & { hasMissingChunks: boolean } {
    return this.withMeetingWriteLock(params.meetingId, () => {
      const dir = this.resolveMeetingDir(params.meetingId);
      this.recoverPendingSaveTxUnlocked(params.meetingId, dir);
      const { manifest, rawText } = this.readManifestWithRaw(params.meetingId);
      if (params.title !== undefined && !isWellFormedUnicode(params.title)) {
        throw new Error("会议标题包含非法未配对 Unicode 代理字符");
      }
      const hasTitleUpdate = typeof params.title === "string" && params.title.trim().length > 0;
      const nextTitle = hasTitleUpdate ? this.validateTitle(params.title!) : "";

      if (manifest.status === "recording" || manifest.status === "finalizing") {
        if (params.kind === "full_transcript" || params.kind === "notes") {
          throw new Error(`会议当前处于 ${manifest.status} 状态，请先停止录制并封包后再生成完整逐字稿或纪要`);
        }
        if (hasTitleUpdate) {
          throw new Error("录制或封包进行中禁止修改 manifest 标题，请在停止后重命名");
        }
      }

      const needsManifestTitleUpdate = hasTitleUpdate && nextTitle !== manifest.title;
      if (needsManifestTitleUpdate) {
        this.preparePatchedManifestText(rawText, { title: nextTitle }, params.meetingId);
      }

      let validatedChunkId: string | undefined;
      if (params.kind === "chunk_transcript") {
        if (!params.chunkId) {
          throw new Error("kind 为 chunk_transcript 时必须提供 chunkId");
        }
        validatedChunkId = this.validateChunkId(params.chunkId);
        const validIds = new Set(manifest.chunks.map((c) => c.id));
        if (!validIds.has(validatedChunkId)) {
          throw new Error(`会议 ${params.meetingId} 中不存在切片 ${validatedChunkId}`);
        }
      } else if (params.chunkId !== undefined) {
        this.validateChunkId(params.chunkId);
      }

      // Validate directory & lease targets BEFORE writing any content or manifest files.
      this.assertSafeSubdir(dir, "transcripts");
      this.assertSafeLeaseTarget(dir);

      let savedPath: string;
      if (params.kind === "chunk_transcript") {
        savedPath = path.join(dir, "transcripts", `${validatedChunkId}.md`);
      } else if (params.kind === "full_transcript") {
        savedPath = path.join(dir, "transcript.md");
      } else {
        savedPath = path.join(dir, "notes.md");
      }

      const preview: SaveResultPreview = {
        savedPath,
        meetingId: params.meetingId,
        kind: params.kind,
        ...(params.kind === "chunk_transcript" ? { chunkId: validatedChunkId } : {}),
      };
      params.beforeCommit?.(preview);

      const { missingChunkIds: preMissingChunkIds } = this.getTranscriptChunkStatus(
        params.meetingId,
        dir,
        manifest.chunks,
      );

      let prevLeaseContent: string | null = null;
      let leaseAction: "none" | "touch" | "clear" = "none";
      if (params.manageLease) {
        const prevLeaseRes = this.readMeetingFileByFd(params.meetingId, null, LEASE_FILE_NAME, {
          maxReadBytes: 64 * 1024,
          allowTruncate: false,
        });
        if (prevLeaseRes.kind === "invalid" || prevLeaseRes.kind === "too_large") {
          throw new Error(`拒绝清理异常转写锁目标: ${LEASE_FILE_NAME}`);
        }
        if (params.kind === "chunk_transcript") {
          leaseAction = "touch";
          prevLeaseContent = prevLeaseRes.kind === "ok" ? prevLeaseRes.content : null;
        } else if (params.kind === "notes" && preMissingChunkIds.length === 0) {
          if (prevLeaseRes.kind === "ok" && !isLeaseExpiredOrInvalid(prevLeaseRes.content)) {
            leaseAction = "clear";
            prevLeaseContent = prevLeaseRes.content;
          }
        }
      }

      let appliedLeaseContent: string | null = null;
      if (leaseAction === "touch") {
        const now = Date.now();
        appliedLeaseContent = JSON.stringify({
          updatedAt: now,
          expiresAt: now + DEFAULT_LEASE_TTL_MS,
        });
      }

      let leaseChanged = false;
      const rollbackLease = (): boolean => {
        if (!leaseChanged) return true;
        try {
          this.rollbackLeaseSafelyUnlocked(params.meetingId, dir, {
            leaseAction,
            prevLeaseContent,
            appliedLeaseContent,
          });
          return true;
        } catch {
          return false;
        }
      };

      if (!needsManifestTitleUpdate && leaseAction === "none") {
        this.atomicWriteFile(savedPath, params.content);
      } else {
        const existingTarget = lstatIfExists(savedPath);
        if (existingTarget && (existingTarget.isSymbolicLink() || !existingTarget.isFile())) {
          throw new Error(`拒绝覆盖符号链接、管道或非普通文件: ${path.basename(savedPath)}`);
        }
        const savedDir = path.dirname(savedPath);
        fs.mkdirSync(savedDir, { recursive: true });
        const savedDirStat = fs.lstatSync(savedDir);
        if (savedDirStat.isSymbolicLink() || !savedDirStat.isDirectory()) {
          throw new Error(`拒绝写入非真实目录: ${savedDir}`);
        }

        const savedSubdir: MeetingSubdir | null =
          params.kind === "chunk_transcript" ? "transcripts" : null;
        const savedBaseName = path.basename(savedPath);
        const prevSavedIdent = this.readFileIdentityByFdUnlocked(
          params.meetingId,
          savedSubdir,
          savedBaseName,
        );
        if (prevSavedIdent.kind === "invalid") {
          throw new Error(`拒绝覆盖符号链接、管道或非普通文件: ${savedBaseName}`);
        }
        const prevSavedIdentity: SavedFileIdentity =
          prevSavedIdent.kind === "missing"
            ? { exists: false }
            : {
                exists: true,
                ...buildFileIdentityFromHash(prevSavedIdent.bigintStat, prevSavedIdent.sha256),
              };

        const savedTmp = this.writeStagingTempFile(savedDir, path.basename(savedPath), params.content);
        const stagedContentSha256 = sha256Hex(Buffer.from(params.content, "utf8"));
        let savedTmpStat: fs.BigIntStats;
        let stagedFileIdentity: FileIdentityRecord;
        try {
          savedTmpStat = fs.lstatSync(savedTmp, { bigint: true });
          stagedFileIdentity = buildFileIdentityFromHash(savedTmpStat, stagedContentSha256);
        } catch (prepErr) {
          try {
            fs.unlinkSync(savedTmp);
          } catch {
            // ignore
          }
          throw prepErr;
        }
        const txPath = path.join(dir, SAVE_TX_FILE_NAME);
        const savedRelPath = path.relative(dir, savedPath).split(path.sep).join("/");
        const stagedTmpRelPath = path.relative(dir, savedTmp).split(path.sep).join("/");
        const baseTxRecord = {
          version: 1,
          createdAt: Date.now(),
          txMode: "body_only" as const,
          meetingId: params.meetingId,
          savedRelPath,
          stagedTmpRelPath,
          prevSavedIdentity,
          stagedFileIdentity,
          leaseAction,
          prevLeaseContent,
          ...(appliedLeaseContent !== null ? { appliedLeaseContent } : {}),
        };
        let currentTxRecord: {
          version: number;
          createdAt: number;
          txMode: "body_only" | "title_and_body";
          meetingId: string;
          savedRelPath: string;
          stagedTmpRelPath: string;
          prevSavedIdentity: SavedFileIdentity;
          stagedFileIdentity: FileIdentityRecord;
          targetTitle?: string;
          prevManifestTitle?: string;
          manifestSwapTmpRelPath?: string;
          preSwapManifestSnapRelPath?: string;
          expectedPreSwapManifestIdentity?: FileIdentityRecord;
          expectedManifestIdentity?: FileIdentityRecord;
          leaseAction: "none" | "touch" | "clear";
          prevLeaseContent: string | null;
          appliedLeaseContent?: string;
        } = { ...baseTxRecord };
        let txWritten = false;
        let manifestCommitted = false;
        let manifestPossiblyCommitted = false;
        let committedPrevTitle: string | null = null;
        let preSwapManifestSnapPath: string | null = null;
        const cleanupPreSwapManifestSnap = () => {
          if (!preSwapManifestSnapPath) return;
          const p = preSwapManifestSnapPath;
          preSwapManifestSnapPath = null;
          try {
            fs.unlinkSync(p);
          } catch {
            // ignore
          }
        };
        let displacedConflict: {
          backupPath: string;
          snapshotRaw: string;
          attemptedTitleToken: string | null;
          detail: string;
        } | null = null;
        let bodyCommitted = false;
        let preserveSavedTmpOnCatch = false;

        try {
          this.atomicWriteFile(txPath, JSON.stringify(currentTxRecord));
          txWritten = true;

          if (leaseAction === "touch") {
            this.touchTranscriptionLeaseUnlocked(
              params.meetingId,
              dir,
              DEFAULT_LEASE_TTL_MS,
              appliedLeaseContent ?? undefined,
            );
            leaseChanged = true;
          } else if (leaseAction === "clear") {
            leaseChanged = this.clearMatchingLeaseUnlocked(
              params.meetingId,
              dir,
              prevLeaseContent,
              {
                onSwapped: () => {
                  leaseChanged = true;
                },
              },
            );
          }

          if (needsManifestTitleUpdate) {
            const titleCommit = this.commitManifestPatchCAS(
              params.meetingId,
              dir,
              (latestRaw, latestM) => {
                if (latestM.status === "recording" || latestM.status === "finalizing") {
                  throw new Error(`会议当前处于 ${latestM.status} 状态，禁止在未结束录制时修改标题`);
                }
                if (latestM.title === nextTitle) {
                  return null;
                }
                committedPrevTitle = latestM.title;
                return this.preparePatchedManifestText(
                  latestRaw,
                  { title: nextTitle },
                  params.meetingId,
                );
              },
              {
                onBeforeCreateTmp: (tmpBaseName) => {
                  cleanupPreSwapManifestSnap();
                  const snapBaseName = `.manifest-snap.${crypto.randomUUID()}.tmp`;
                  preSwapManifestSnapPath = path.join(dir, snapBaseName);
                  currentTxRecord = {
                    ...baseTxRecord,
                    manifestSwapTmpRelPath: tmpBaseName,
                    preSwapManifestSnapRelPath: snapBaseName,
                  };
                  this.atomicWriteFile(txPath, JSON.stringify(currentTxRecord));
                },
                onBeforeSwap: (myStat, contentBytes, tmpPath, expectedStat, expectedRawBytes) => {
                  const snapBaseName = preSwapManifestSnapPath
                    ? path.basename(preSwapManifestSnapPath)
                    : `.manifest-snap.${crypto.randomUUID()}.tmp`;
                  cleanupPreSwapManifestSnap();
                  preSwapManifestSnapPath = this.writeStagingTempFileAtName(
                    dir,
                    snapBaseName,
                    expectedRawBytes.toString("utf8"),
                  );
                  currentTxRecord = {
                    ...baseTxRecord,
                    txMode: "title_and_body",
                    targetTitle: nextTitle,
                    prevManifestTitle: committedPrevTitle ?? manifest.title,
                    manifestSwapTmpRelPath: path.basename(tmpPath),
                    preSwapManifestSnapRelPath: path.basename(preSwapManifestSnapPath),
                    expectedPreSwapManifestIdentity: buildFileIdentity(
                      expectedStat,
                      expectedRawBytes,
                    ),
                    expectedManifestIdentity: buildFileIdentity(myStat, contentBytes),
                  };
                  this.atomicWriteFile(txPath, JSON.stringify(currentTxRecord));
                },
                onSwapExecuted: () => {
                  manifestPossiblyCommitted = true;
                },
                onSwapReverted: () => {
                  manifestPossiblyCommitted = false;
                },
                onConflictBackup: (info) => {
                  displacedConflict = {
                    ...info,
                    attemptedTitleToken: JSON.stringify(nextTitle),
                  };
                },
              },
            );
            cleanupPreSwapManifestSnap();
            if (!titleCommit.skipped) {
              committedPrevTitle = titleCommit.manifest.title;
              manifestCommitted = true;
            } else if (
              currentTxRecord.txMode === "title_and_body" ||
              currentTxRecord.manifestSwapTmpRelPath !== undefined ||
              currentTxRecord.preSwapManifestSnapRelPath !== undefined
            ) {
              currentTxRecord = { ...baseTxRecord };
              try {
                this.atomicWriteFile(txPath, JSON.stringify(currentTxRecord));
              } catch {
                // Best effort; expectedManifestIdentity also prevents roll-forward on external title writes.
              }
            }
          }

          const preRenameTarget = lstatIfExists(savedPath);
          if (preRenameTarget && (preRenameTarget.isSymbolicLink() || !preRenameTarget.isFile())) {
            throw new Error(`拒绝覆盖符号链接、管道或非普通文件: ${path.basename(savedPath)}`);
          }
          if (prevSavedIdent.kind === "missing") {
            try {
              safeOpenat.renamex_excl(savedTmp, savedPath);
            } catch (exclErr) {
              if ((exclErr as NodeJS.ErrnoException | undefined)?.code === "EEXIST") {
                throw new Error(
                  `保存正文时检测到外部并发新建 ${savedBaseName}，已取消保存以保护外部正文: ${params.meetingId}`,
                );
              }
              throw exclErr;
            }
            bodyCommitted = true;
          } else {
            const bodyCas = this.atomicSwapStagedFileWithIdentity({
              meetingId: params.meetingId,
              subdir: savedSubdir,
              stagedBase: path.basename(savedTmp),
              savedBase: savedBaseName,
              stagedTmpPath: savedTmp,
              savedPath,
              expectedTargetStat: prevSavedIdent.bigintStat,
              expectedTargetSha256: prevSavedIdent.sha256,
              stagedStat: savedTmpStat,
              stagedSha256: stagedContentSha256,
            });
            if (bodyCas.kind === "conflict") {
              if (!bodyCas.preservedLatest && bodyCas.backupPath) {
                preserveSavedTmpOnCatch = true;
                throw new Error(
                  `保存正文时检测到外部并发写入且回退失败，外部正文已备份于 ${bodyCas.backupPath}: ${params.meetingId}`,
                );
              }
              throw new Error(
                `保存正文时检测到外部并发修改 ${savedBaseName}，已取消保存以保护外部正文: ${params.meetingId}`,
              );
            }
            bodyCommitted = true;
            try {
              fs.unlinkSync(savedTmp);
            } catch {
              // Best effort cleanup of displaced old body temp file.
            }
          }
        } catch (err) {
          const capturedConflict = displacedConflict as {
            backupPath: string;
            snapshotRaw: string;
            attemptedTitleToken: string | null;
            detail: string;
          } | null;
          const needsTitleRollback = manifestCommitted || manifestPossiblyCommitted;
          const mergeResult = needsTitleRollback
            ? this.rollbackAndMergeManifestUnlocked({
                meetingId: params.meetingId,
                dir,
                nextTitle,
                fallbackPrevTitle: committedPrevTitle ?? manifest.title,
                initialConflict: capturedConflict,
              })
            : {
                resolved: true,
                mergedAndDeletedBackups: [],
                retainedBackups: [],
                deferredMerges: [],
              };
          const titleRollbackResolved = mergeResult.resolved;

          const leaseRollbackResolved = titleRollbackResolved ? rollbackLease() : true;
          if (titleRollbackResolved && leaseRollbackResolved) {
            if (mergeResult.deferredMerges.length > 0) {
              let deferredMarked = false;
              if (txWritten) {
                try {
                  this.atomicWriteFile(
                    txPath,
                    JSON.stringify({
                      ...currentTxRecord,
                      phase: "aborted",
                      pendingManifestMerges: mergeResult.deferredMerges,
                    }),
                  );
                  deferredMarked = true;
                } catch {
                  deferredMarked = false;
                }
              }
              if (deferredMarked) {
                cleanupPreSwapManifestSnap();
                if (!preserveSavedTmpOnCatch) {
                  try {
                    fs.unlinkSync(savedTmp);
                  } catch {
                    // ignore
                  }
                }
              }
            } else {
              let abortMarked = !txWritten;
              if (txWritten) {
                try {
                  this.atomicWriteFile(
                    txPath,
                    JSON.stringify({ ...currentTxRecord, phase: "aborted" }),
                  );
                  abortMarked = true;
                } catch {
                  abortMarked = false;
                }
              }
              if (abortMarked) {
                cleanupPreSwapManifestSnap();
                let stagedUnlinked = false;
                if (preserveSavedTmpOnCatch) {
                  stagedUnlinked = true;
                } else {
                  try {
                    fs.unlinkSync(savedTmp);
                    stagedUnlinked = true;
                  } catch (unlinkTmpErr) {
                    if ((unlinkTmpErr as NodeJS.ErrnoException | undefined)?.code === "ENOENT") {
                      stagedUnlinked = true;
                    }
                  }
                }
                if (txWritten && stagedUnlinked) {
                  try {
                    fs.unlinkSync(txPath);
                  } catch {
                    // ignore
                  }
                }
              }
            }
          }

          const origMsg = err instanceof Error ? err.message : String(err);
          const retained = [...new Set(mergeResult.retainedBackups)];
          const mergedCount = mergeResult.mergedAndDeletedBackups.length;
          const initialWasDeleted =
            capturedConflict !== null &&
            mergeResult.mergedAndDeletedBackups.includes(capturedConflict.backupPath);
          const safeOrigMsg = initialWasDeleted
            ? `manifest.json 发生外部冲突，初次冲突变更已自动合并: ${params.meetingId}`
            : origMsg;

          if (!titleRollbackResolved) {
            const missingRetained = retained.filter((p) => !safeOrigMsg.includes(p));
            const retainedSuffix =
              missingRetained.length > 0
                ? `（已保留外部清单备份于 ${missingRetained.join(", ")}）`
                : "";
            throw new Error(
              `保存正文失败且标题回滚失败，已保留事务日志与暂存正文用于下次自动恢复${retainedSuffix}: ${safeOrigMsg}`,
            );
          }

          if (retained.length > 0) {
            if (initialWasDeleted) {
              throw new Error(
                `保存失败：manifest.json 发生外部并发修改，非冲突外部变更已合并，存在同字段冲突已保留外部清单备份于 ${retained.join(", ")}: ${params.meetingId}`,
              );
            }
            const missingBackups = retained.filter((p) => !safeOrigMsg.includes(p));
            if (missingBackups.length > 0) {
              throw new Error(
                `${safeOrigMsg}（并发回滚合并存在同字段冲突，已保留外部清单备份于 ${missingBackups.join(", ")}）`,
              );
            }
            throw err;
          }

          if (mergedCount > 0) {
            if (initialWasDeleted) {
              throw new Error(
                `保存失败：manifest.json 发生外部冲突，非冲突外部变更已自动合并回清单，本次保存已取消: ${params.meetingId}`,
              );
            }
            throw new Error(
              `${safeOrigMsg}（回滚期间检测到 manifest.json 外部并发修改，非冲突外部变更已自动合并回清单，本次保存已取消）`,
            );
          }

          throw err;
        }

        if (leaseAction === "clear" && leaseChanged) {
          let finalCheckManifest: MeetingManifest;
          let finalMissingChunkIds: string[];
          try {
            finalCheckManifest = this.readManifestWithRaw(params.meetingId).manifest;
            finalMissingChunkIds = this.getTranscriptChunkStatus(
              params.meetingId,
              dir,
              finalCheckManifest.chunks,
            ).missingChunkIds;
          } catch (finalCheckErr) {
            this.rollbackLeaseSafelyUnlocked(params.meetingId, dir, {
              leaseAction: "clear",
              prevLeaseContent,
            });
            throw finalCheckErr;
          }
          if (
            finalCheckManifest.status === "recording" ||
            finalCheckManifest.status === "finalizing" ||
            finalMissingChunkIds.length > 0
          ) {
            this.rollbackLeaseSafelyUnlocked(params.meetingId, dir, {
              leaseAction: "clear",
              prevLeaseContent,
            });
          }
        }

        if (bodyCommitted && txWritten) {
          try {
            fs.unlinkSync(txPath);
          } catch {
            // Post-commit best effort; stagedTmp is already gone so subsequent recovery unlinks txPath idempotently.
          }
        }
      }

      const latestManifestForChunks = this.readManifestWithRaw(params.meetingId).manifest;
      const { missingChunkIds } = this.getTranscriptChunkStatus(
        params.meetingId,
        dir,
        latestManifestForChunks.chunks,
      );

      return {
        ...preview,
        hasMissingChunks: missingChunkIds.length > 0,
      };
    });
  }

  renameMeeting(
    meetingId: string,
    title: string,
    beforeCommit?: (preview: MeetingViewManifest) => void,
  ): MeetingManifest {
    const trimmed = this.validateTitle(title);
    return this.withMeetingWriteLock(meetingId, () => {
      const dir = this.resolveMeetingDir(meetingId);
      this.recoverPendingSaveTxUnlocked(meetingId, dir);
      const { manifest, rawText } = this.readManifestWithRaw(meetingId);
      if (manifest.status === "recording" || manifest.status === "finalizing") {
        throw new Error(`会议当前处于 ${manifest.status} 状态，禁止在未结束录制时重命名`);
      }
      this.preparePatchedManifestText(rawText, { title: trimmed }, meetingId);
      const updatedManifest: MeetingManifest = { ...manifest, title: trimmed };
      beforeCommit?.(this.toViewManifest(updatedManifest));
      this.commitManifestPatchCAS(meetingId, dir, (latestRaw, latestM) => {
        if (latestM.status === "recording" || latestM.status === "finalizing") {
          throw new Error(`会议当前处于 ${latestM.status} 状态，禁止在未结束录制时重命名`);
        }
        return this.preparePatchedManifestText(latestRaw, { title: trimmed }, meetingId);
      });
      return updatedManifest;
    });
  }

  private collectOwnedLiveTargets(
    dir: string,
    manifest: MeetingManifest,
    options?: { strict?: boolean; throwOnReadError?: boolean },
  ): Array<{
    sub: "chunks";
    full: string;
    dev: number;
    ino: number;
    size: number;
  }> {
    const referencedChunkFiles = new Set<string>();
    for (const c of manifest.chunks) {
      for (const rel of [c.audioPath, c.micPath, c.remotePath]) {
        if (typeof rel !== "string" || rel.includes("..")) continue;
        const m = CHUNK_REL_PATH_RE.exec(rel);
        if (m) referencedChunkFiles.add(m[1]);
      }
    }

    const targets: Array<{
      sub: "chunks";
      full: string;
      dev: number;
      ino: number;
      size: number;
    }> = [];

    try {
      const safeSub = this.assertSafeSubdir(dir, "chunks");
      if (!safeSub || referencedChunkFiles.size === 0) return targets;
      const matchedEntries: Array<{ full: string; lst: fs.Stats }> = [];
      for (const entry of fs.readdirSync(safeSub)) {
        if (!CHUNK_REL_PATH_RE.test(`chunks/${entry}`)) continue;
        if (!referencedChunkFiles.has(entry)) continue;
        const full = path.join(safeSub, entry);
        const lst = lstatIfExists(full);
        if (!lst) continue;
        if (lst.isSymbolicLink() || !lst.isFile()) {
          if (options?.strict) {
            throw new Error(`拒绝清理非普通文件或符号链接: chunks/${entry}`);
          }
          continue;
        }
        matchedEntries.push({ full, lst });
      }
      if (matchedEntries.length > 0 && options?.strict) {
        fs.accessSync(safeSub, fs.constants.W_OK | fs.constants.X_OK);
      }
      for (const item of matchedEntries) {
        targets.push({
          sub: "chunks",
          full: item.full,
          dev: item.lst.dev,
          ino: item.lst.ino,
          size: item.lst.size,
        });
      }
    } catch (err) {
      if (options?.strict || options?.throwOnReadError) {
        throw err;
      }
    }

    return targets;
  }

  private scanOwnedStagingFiles(
    dir: string,
    options?: { requireWritable?: boolean; throwOnUnreadable?: boolean },
  ): {
    stagingDirs: string[];
    stagedFiles: Array<{
      sub: "chunks";
      stagedPath: string;
      dev: number;
      ino: number;
      size: number;
    }>;
    unreadableStagingDirs: string[];
  } {
    const stagingDirs: string[] = [];
    const stagedFiles: Array<{
      sub: "chunks";
      stagedPath: string;
      dev: number;
      ino: number;
      size: number;
    }> = [];
    const unreadableStagingDirs: string[] = [];

    for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
      if (!CLEANUP_STAGING_DIR_RE.test(ent.name)) continue;
      const stagingPath = path.join(dir, ent.name);
      const stLst = lstatIfExists(stagingPath);
      if (!stLst || stLst.isSymbolicLink() || !stLst.isDirectory()) continue;

      try {
        const childNames = fs.readdirSync(stagingPath);
        const dirOwnedFiles: Array<{
          sub: "chunks";
          stagedPath: string;
          dev: number;
          ino: number;
          size: number;
        }> = [];
        for (const fName of childNames) {
          const sub = isOwnedStagedFileName(fName);
          if (!sub) continue;
          const full = path.join(stagingPath, fName);
          const lst = lstatIfExists(full);
          if (!lst || lst.isSymbolicLink() || !lst.isFile()) continue;
          dirOwnedFiles.push({
            sub,
            stagedPath: full,
            dev: lst.dev,
            ino: lst.ino,
            size: lst.size,
          });
        }

        if (childNames.length === 0 || dirOwnedFiles.length > 0) {
          if (options?.requireWritable) {
            fs.accessSync(stagingPath, fs.constants.W_OK | fs.constants.X_OK);
          }
          stagingDirs.push(stagingPath);
          stagedFiles.push(...dirOwnedFiles);
        }
      } catch (err) {
        const code = (err as NodeJS.ErrnoException | undefined)?.code;
        if (options?.throwOnUnreadable || (code !== "EACCES" && code !== "EPERM" && code !== "ENOTDIR")) {
          throw err;
        }
        unreadableStagingDirs.push(stagingPath);
      }
    }

    return { stagingDirs, stagedFiles, unreadableStagingDirs };
  }

  private buildAudioCleanedFalseManifestText(rawText: string): string | null {
    const candidateFalse = patchTopLevelJsonFields(rawText, { audioCleaned: false });
    if (Buffer.byteLength(candidateFalse, "utf8") <= MAX_SAFE_MANIFEST_BYTES) {
      return candidateFalse;
    }
    const candidateCompactFalse = patchTopLevelJsonFields(
      rawText,
      { audioCleaned: false },
      { compactMissing: true },
    );
    if (Buffer.byteLength(candidateCompactFalse, "utf8") <= MAX_SAFE_MANIFEST_BYTES) {
      return candidateCompactFalse;
    }
    const candidateRemoved = removeTopLevelJsonField(rawText, "audioCleaned");
    if (Buffer.byteLength(candidateRemoved, "utf8") <= MAX_SAFE_MANIFEST_BYTES) {
      return candidateRemoved;
    }
    return null;
  }

  private reconcileAudioCleanedIfLiveTargetsArrivedUnlocked(meetingId: string, dir: string): void {
    const latest = this.readManifestWithRaw(meetingId);
    if (
      !latest.manifest.audioCleaned ||
      latest.manifest.status === "recording" ||
      latest.manifest.status === "finalizing"
    ) {
      return;
    }
    let hasLive = false;
    let scanError: unknown = null;
    try {
      hasLive =
        this.collectOwnedLiveTargets(dir, latest.manifest, {
          strict: false,
          throwOnReadError: true,
        }).length > 0;
    } catch (err) {
      scanError = err;
    }
    if (!hasLive && !scanError) {
      return;
    }
    this.commitManifestPatchCAS(meetingId, dir, (latestRaw, latestM) => {
      if (
        !latestM.audioCleaned ||
        latestM.status === "recording" ||
        latestM.status === "finalizing"
      ) {
        return null;
      }
      if (!scanError) {
        try {
          if (
            this.collectOwnedLiveTargets(dir, latestM, {
              strict: false,
              throwOnReadError: true,
            }).length === 0
          ) {
            return null;
          }
        } catch (confirmErr) {
          scanError = confirmErr;
        }
      }
      return this.buildAudioCleanedFalseManifestText(latestRaw);
    });
    if (scanError) {
      throw scanError;
    }
  }

  cleanupAudio(meetingId: string): { freedBytes: number; meetingId: string } {
    return this.withMeetingWriteLock(meetingId, () => {
      const dir = this.resolveMeetingDir(meetingId);
      this.recoverPendingSaveTxUnlocked(meetingId, dir);
      const { manifest, rawText } = this.readManifestWithRaw(meetingId);
      if (manifest.status === "recording" || manifest.status === "finalizing") {
        throw new Error(`磁盘清单显示会议处于 ${manifest.status} 状态，禁止在未结束录制时修改或删除`);
      }
      if (this.isTranscribingUnlocked(meetingId, dir)) {
        throw new Error(`会议 ${meetingId} 当前正在进行转写，禁止删除或清理原音频`);
      }
      this.preparePatchedManifestText(rawText, { audioCleaned: true }, meetingId);

      // Phase 0: Pre-flight validation and writability check before moving any files.
      fs.accessSync(dir, fs.constants.W_OK | fs.constants.X_OK);
      const targets = this.collectOwnedLiveTargets(dir, manifest, { strict: true });

      // Recover only plugin-owned staged files from prior interrupted/failed Phase 2 unlink attempts.
      const { stagingDirs: leftoverStagingDirs, stagedFiles: leftoverStaged } =
        this.scanOwnedStagingFiles(dir, { requireWritable: true, throwOnUnreadable: true });

      let phase1ManifestPossiblySet = false;
      const commitCleanedFlag = () => {
        this.commitManifestPatchCAS(
          meetingId,
          dir,
          (latestRaw, latestM) => {
            if (latestM.status === "recording" || latestM.status === "finalizing") {
              throw new Error(`磁盘清单显示会议处于 ${latestM.status} 状态，禁止在未结束录制时修改或删除`);
            }
            const remainingLive = this.collectOwnedLiveTargets(dir, latestM, {
              strict: false,
              throwOnReadError: true,
            });
            const targetCleaned = remainingLive.length === 0;
            if (latestM.audioCleaned === targetCleaned) {
              return null;
            }
            return this.preparePatchedManifestText(latestRaw, { audioCleaned: targetCleaned }, meetingId);
          },
          {
            onSwapExecuted: () => {
              phase1ManifestPossiblySet = true;
            },
            onSwapReverted: () => {
              phase1ManifestPossiblySet = false;
            },
          },
        );
      };

      if (targets.length === 0 && leftoverStaged.length === 0) {
        for (const d of leftoverStagingDirs) {
          try {
            fs.rmdirSync(d);
          } catch {
            // ignore
          }
        }
        if (this.isTranscribingUnlocked(meetingId, dir)) {
          throw new Error(`会议 ${meetingId} 当前正在进行转写，禁止删除或清理原音频`);
        }
        commitCleanedFlag();
        this.reconcileAudioCleanedIfLiveTargetsArrivedUnlocked(meetingId, dir);
        return { freedBytes: 0, meetingId };
      }

      // Phase 1: Move validated targets into reversible staging directory and commit manifest via CAS first.
      let trashDir: string | null = null;
      let revertMarker: string | null = null;
      let revertMarkerRemoved = false;
      const moved: Array<{ origPath: string; stagedPath: string; dev: number; ino: number; size: number }> = [];
      if (targets.length > 0) {
        trashDir = path.join(dir, `.cleanup-staging.${crypto.randomUUID()}`);
        fs.mkdirSync(trashDir, { mode: 0o700 });
        revertMarker = path.join(trashDir, CLEANUP_REVERT_MARKER);
        try {
          for (let i = 0; i < targets.length; i += 1) {
            const t = targets[i];
            const lstNow = lstatIfExists(t.full);
            if (!lstNow) continue;
            if (lstNow.isSymbolicLink() || !lstNow.isFile()) {
              throw new Error(`清理目标类型在执行前发生变化: ${path.basename(t.full)}`);
            }
            const stagedPath = path.join(
              trashDir,
              buildStagedFileName(i, t.sub, path.basename(t.full)),
            );
            fs.renameSync(t.full, stagedPath);
            moved.push({
              origPath: t.full,
              stagedPath,
              dev: lstNow.dev,
              ino: lstNow.ino,
              size: lstNow.size,
            });
          }

          if (this.isTranscribingUnlocked(meetingId, dir)) {
            throw new Error(`会议 ${meetingId} 当前正在进行转写，禁止删除或清理原音频`);
          }
          fs.writeFileSync(revertMarker, "1", { mode: 0o600 });
          commitCleanedFlag();
          try {
            fs.unlinkSync(revertMarker);
            revertMarkerRemoved = true;
          } catch (unlinkMarkerErr) {
            if ((unlinkMarkerErr as NodeJS.ErrnoException | undefined)?.code === "ENOENT") {
              revertMarkerRemoved = true;
            }
          }
        } catch (err) {
          let allRestored = true;
          for (let i = moved.length - 1; i >= 0; i -= 1) {
            try {
              safeOpenat.renamex_excl(moved[i].stagedPath, moved[i].origPath);
            } catch {
              allRestored = false;
            }
          }
          let flagReverted = !phase1ManifestPossiblySet;
          if (phase1ManifestPossiblySet) {
            try {
              this.commitManifestPatchCAS(meetingId, dir, (latestRaw, latestM) => {
                if (
                  !latestM.audioCleaned ||
                  latestM.status === "recording" ||
                  latestM.status === "finalizing"
                ) {
                  return null;
                }
                return this.buildAudioCleanedFalseManifestText(latestRaw);
              });
              flagReverted = true;
            } catch {
              flagReverted = false;
            }
          }
          if (flagReverted) {
            try {
              fs.unlinkSync(revertMarker);
            } catch {
              // ignore
            }
          }
          if (allRestored) {
            if (flagReverted) {
              try {
                fs.rmdirSync(trashDir);
              } catch {
                // ignore non-empty/missing dir
              }
            }
            throw err;
          }
          const errMsg = err instanceof Error ? err.message : String(err);
          throw new Error(`清理失败且部分文件未能恢复，已保留暂存目录 ${trashDir}: ${errMsg}`);
        }
      } else {
        if (this.isTranscribingUnlocked(meetingId, dir)) {
          throw new Error(`会议 ${meetingId} 当前正在进行转写，禁止删除或清理原音频`);
        }
        commitCleanedFlag();
      }

      this.reconcileAudioCleanedIfLiveTargetsArrivedUnlocked(meetingId, dir);

      // Phase 2: Permanently unlink staged files and count freedBytes ONLY when last POSIX link is removed.
      const allStaged = [...moved, ...leftoverStaged];
      const groups = new Map<string, Array<{ stagedPath: string; size: number }>>();
      for (const item of allStaged) {
        const key = `${item.dev}:${item.ino}`;
        const list = groups.get(key) ?? [];
        list.push({ stagedPath: item.stagedPath, size: item.size });
        groups.set(key, list);
      }

      let freedBytes = 0;
      let anyUnlinkFailed = false;
      for (const group of groups.values()) {
        const firstStat = lstatIfExists(group[0].stagedPath);
        const totalLinks = firstStat ? firstStat.nlink : 0;
        const inodeSize = firstStat ? firstStat.size : group[0].size;
        let removedCount = 0;
        for (const entry of group) {
          try {
            fs.unlinkSync(entry.stagedPath);
            removedCount += 1;
          } catch (err) {
            if ((err as NodeJS.ErrnoException | undefined)?.code !== "ENOENT") {
              anyUnlinkFailed = true;
            }
          }
        }
        if (totalLinks > 0 && totalLinks <= removedCount) {
          freedBytes += inodeSize;
        }
      }

      if (revertMarker && !revertMarkerRemoved && !anyUnlinkFailed) {
        try {
          fs.unlinkSync(revertMarker);
          revertMarkerRemoved = true;
        } catch (unlinkMarkerErr) {
          if ((unlinkMarkerErr as NodeJS.ErrnoException | undefined)?.code === "ENOENT") {
            revertMarkerRemoved = true;
          }
        }
      }

      for (const d of [trashDir, ...leftoverStagingDirs]) {
        if (!d) continue;
        try {
          fs.rmdirSync(d);
        } catch {
          // Non-recursive: leaves staging dir intact if any unlinkSync failed or untracked files exist.
        }
      }

      if (anyUnlinkFailed) {
        let manifestReverted = false;
        let manifestConflict = false;
        let conflictBackupPath: string | null = null;
        let revertErrorMsg: string | null = null;

        try {
          const latest = this.readManifestWithRaw(meetingId);
          if (latest.manifest.status === "recording" || latest.manifest.status === "finalizing") {
            manifestConflict = true;
          } else if (!latest.manifest.audioCleaned) {
            manifestReverted = true;
          } else {
            const revertedManifestText = this.buildAudioCleanedFalseManifestText(latest.rawText);
            if (revertedManifestText === null) {
              manifestConflict = true;
            } else {
              const cas = this.atomicCompareAndSwapFile(
                path.join(dir, "manifest.json"),
                revertedManifestText,
                latest.bigintStat,
                latest.rawBytes,
              );
              if (cas.kind === "swapped") {
                manifestReverted = true;
              } else {
                manifestConflict = true;
                if (cas.backupPath) {
                  conflictBackupPath = cas.backupPath;
                }
              }
            }
          }
        } catch (err) {
          revertErrorMsg = err instanceof Error ? err.message : String(err);
        }

        if (manifestReverted) {
          throw new Error(
            `部分暂存音频未能彻底删除（本次释放 ${freedBytes} B），未删除文件已保留在暂存目录并恢复为未清理状态，可稍后重试清理`,
          );
        }
        if (conflictBackupPath !== null) {
          throw new Error(
            `部分暂存音频未能彻底删除（本次释放 ${freedBytes} B），回退 manifest.json 时发生外部冲突且交换失败，外部清单备份已保留在 ${conflictBackupPath}，未删除文件已保留在暂存目录`,
          );
        }
        if (manifestConflict) {
          throw new Error(
            `部分暂存音频未能彻底删除（本次释放 ${freedBytes} B），且检测到磁盘 manifest.json 已被外部修改或超过 16 MiB 上限，已保留磁盘当前清单与暂存目录（未回退 audioCleaned）`,
          );
        }
        throw new Error(
          `部分暂存音频未能彻底删除（本次释放 ${freedBytes} B），且未能回退 manifest.json（${revertErrorMsg ?? "未知错误"}），磁盘原清单与暂存目录均已保留`,
        );
      }

      this.reconcileAudioCleanedIfLiveTargetsArrivedUnlocked(meetingId, dir);
      return { freedBytes, meetingId };
    });
  }

  deleteMeeting(meetingId: string): { deleted: boolean; meetingId: string } {
    return this.withMeetingWriteLock(meetingId, () => {
      const dir = this.resolveMeetingDir(meetingId);
      if (!lstatIfExists(dir)) {
        throw new Error(`会议不存在: ${meetingId}`);
      }
      this.recoverPendingSaveTxUnlocked(meetingId, dir);
      const { manifest } = this.readManifestWithRaw(meetingId);
      if (manifest.status === "recording" || manifest.status === "finalizing") {
        throw new Error(`磁盘清单显示会议处于 ${manifest.status} 状态，禁止在未结束录制时修改或删除`);
      }
      if (this.isTranscribingUnlocked(meetingId, dir)) {
        throw new Error(`会议 ${meetingId} 当前正在进行转写，禁止删除或清理原音频`);
      }
      for (const sub of ["chunks", "timelines", "transcripts", ".commits"] as const) {
        this.assertSafeSubdir(dir, sub);
      }
      if (this.isTranscribingUnlocked(meetingId, dir)) {
        throw new Error(`会议 ${meetingId} 当前正在进行转写，禁止删除或清理原音频`);
      }
      fs.rmSync(dir, { recursive: true, force: true });
      return { deleted: true, meetingId };
    });
  }

  private loadAllMeetingSummaries(): MeetingSummary[] {
    this.ensureRoot();
    const entries = fs.readdirSync(this.meetingsDir, { withFileTypes: true });
    const summaries: MeetingSummary[] = [];

    for (const ent of entries) {
      if (ent.isSymbolicLink() || !ent.isDirectory() || !MEETING_ID_RE.test(ent.name)) continue;
      try {
        const dir = this.resolveMeetingDir(ent.name);
        const manifest = this.readManifest(ent.name);
        summaries.push(this.toSummary(ent.name, dir, manifest));
      } catch {
        // Ignore invalid/corrupted folders so one bad directory never breaks listing or search.
      }
    }

    summaries.sort((a, b) => (a.createdAt < b.createdAt ? 1 : a.createdAt > b.createdAt ? -1 : 0));
    return summaries;
  }

  listMeetings(limit = 50, offset = 0): { total: number; items: MeetingSummary[] } {
    const summaries = this.loadAllMeetingSummaries();
    const safeOffset = Math.max(0, offset);
    const safeLimit = Math.min(200, Math.max(1, limit));
    return {
      total: summaries.length,
      items: summaries.slice(safeOffset, safeOffset + safeLimit),
    };
  }

  searchMeetings(query: string, limit = 20): SearchHit[] {
    const q = query.trim().toLowerCase();
    if (!q) return [];
    const items = this.loadAllMeetingSummaries();
    const hits: SearchHit[] = [];

    for (const item of items) {
      try {
        if (typeof item.title !== "string") continue;
        const matchedIn: ("title" | "notes" | "transcript")[] = [];
        let snippet = "";

        if (item.title.toLowerCase().includes(q)) {
          matchedIn.push("title");
        }

        const notesRes = this.readMeetingFileByFd(item.id, null, "notes.md", {
          maxReadBytes: MAX_SAFE_TEXT_READ_BYTES,
          allowTruncate: true,
        });
        if (notesRes.kind === "ok" && notesRes.content.length > 0) {
          const idx = notesRes.content.toLowerCase().indexOf(q);
          if (idx >= 0) {
            matchedIn.push("notes");
            snippet = this.extractSnippet(notesRes.content, idx, q.length);
          }
        }

        const transcriptRes = this.readMeetingFileByFd(item.id, null, "transcript.md", {
          maxReadBytes: MAX_SAFE_TEXT_READ_BYTES,
          allowTruncate: true,
        });
        if (transcriptRes.kind === "ok" && transcriptRes.content.length > 0) {
          const idx = transcriptRes.content.toLowerCase().indexOf(q);
          if (idx >= 0) {
            matchedIn.push("transcript");
            if (!snippet) {
              snippet = this.extractSnippet(transcriptRes.content, idx, q.length);
            }
          }
        }

        if (matchedIn.length > 0) {
          hits.push({
            id: item.id,
            title: item.title,
            mode: item.mode,
            createdAt: item.createdAt,
            totalDurationSec: item.totalDurationSec,
            hasNotes: item.hasNotes,
            hasTranscript: item.hasTranscript,
            matchedIn,
            snippet: snippet || item.title,
          });
          if (hits.length >= limit) break;
        }
      } catch {
        // Ignore individual corrupted folders during search.
      }
    }

    return hits;
  }

  private extractSnippet(text: string, idx: number, matchLen: number): string {
    const start = Math.max(0, idx - 40);
    const end = Math.min(text.length, idx + matchLen + 80);
    const raw = text.slice(start, end).replace(/\s+/g, " ").trim();
    return `${start > 0 ? "..." : ""}${raw}${end < text.length ? "..." : ""}`;
  }

  private toSummary(meetingId: string, dir: string, manifest: MeetingManifest): MeetingSummary {
    const chunks = manifest.chunks;
    const { transcribedChunkIds, missingChunkIds } = this.getTranscriptChunkStatus(meetingId, dir, chunks);
    const transcriptStat = this.statMeetingFileByFd(meetingId, null, "transcript.md");
    const notesStat = this.statMeetingFileByFd(meetingId, null, "notes.md");

    const seenInodes = new Set<string>();
    let audioBytesTotal = 0;
    let liveCleanableCount = 0;
    const liveTargets = this.collectOwnedLiveTargets(dir, manifest, { strict: false });
    for (const t of liveTargets) {
      liveCleanableCount += 1;
      if (t.sub === "chunks") {
        const inodeKey = `${t.dev}:${t.ino}`;
        if (!seenInodes.has(inodeKey)) {
          seenInodes.add(inodeKey);
          audioBytesTotal += t.size;
        }
      }
    }

    let hasPendingStaging = false;
    try {
      const ownedStaging = this.scanOwnedStagingFiles(dir);
      hasPendingStaging =
        ownedStaging.stagedFiles.length > 0 || ownedStaging.unreadableStagingDirs.length > 0;
      for (const f of ownedStaging.stagedFiles) {
        if (f.sub === "chunks") {
          const inodeKey = `${f.dev}:${f.ino}`;
          if (!seenInodes.has(inodeKey)) {
            seenInodes.add(inodeKey);
            audioBytesTotal += f.size;
          }
        }
      }
    } catch {
      hasPendingStaging = true;
    }

    const hasNotes = Boolean(notesStat && notesStat.size > 0);
    const notesRevision =
      hasNotes && notesStat
        ? `${notesStat.size}:${notesStat.ino}:${notesStat.mtimeMs}:${notesStat.ctimeMs}`
        : undefined;
    const hasCleanableAudio = hasPendingStaging || liveCleanableCount > 0;
    return {
      id: manifest.id,
      title: manifest.title,
      mode: manifest.mode,
      appTarget: manifest.appTarget ?? (manifest.mode === "dual" ? "all_system" : "mic_only"),
      status: manifest.status,
      createdAt: manifest.createdAt,
      endedAt: manifest.endedAt,
      totalDurationSec: manifest.totalDurationSec ?? 0,
      chunkCount: chunks.length,
      transcribedChunkCount: transcribedChunkIds.length,
      missingChunkCount: missingChunkIds.length,
      failedChunkCount: manifest.failedChunkCount ?? 0,
      hasTranscript: Boolean(transcriptStat && transcriptStat.size > 0),
      hasNotes,
      ...(notesRevision !== undefined ? { notesRevision } : {}),
      audioCleaned: Boolean(manifest.audioCleaned) && !hasCleanableAudio,
      audioBytesTotal,
      hasCleanableAudio,
    };
  }
}
