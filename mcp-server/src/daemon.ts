import { execFile } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { promisify } from "node:util";
import type { ServerConfig } from "./config.js";

const execFileAsync = promisify(execFile);
const VALID_RECORDER_STATES = new Set(["idle", "starting", "recording", "finalizing", "error"]);

function isValidRecorderState(value: unknown): value is string {
  return typeof value === "string" && VALID_RECORDER_STATES.has(value);
}

export interface ChunkRecord {
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
  committedAt: string;
}

export interface GapRecord {
  startSec: number;
  endSec: number;
  reason: string;
}

export interface MeetingManifest {
  schemaVersion: number;
  id: string;
  title: string;
  mode: "mic" | "dual" | string;
  appTarget: string;
  status: "recording" | "finalizing" | "recorded" | "partial" | "empty" | string;
  createdAt: string;
  endedAt?: string;
  totalDurationSec: number;
  chunks: ChunkRecord[];
  gaps: GapRecord[];
  audioCleaned: boolean;
  failedChunkCount?: number;
  hostTimeOriginNs?: number;
  lastError?: string;
}

export interface SpeakerSegment {
  startSec: number;
  endSec: number;
  speaker: "me" | "remote" | "both" | string;
  micDb: number;
  remoteDb: number;
}

export interface ChunkTimeline {
  schemaVersion: number;
  chunkId: string;
  chunkIndex: number;
  audioRangeSec: [number, number];
  responsibleRangeSec: [number, number];
  windowMs: number;
  segments: SpeakerSegment[];
}

export interface RecorderStateSnapshot {
  state: "idle" | "starting" | "recording" | "finalizing" | "error" | string;
  meetingId?: string;
  title?: string;
  mode?: string;
  elapsedSec: number;
  meLevel: number;
  remoteLevel: number;
  committedChunkCount: number;
  chunks: ChunkRecord[];
  gaps?: GapRecord[];
  failedChunkCount?: number;
  inputDeviceName?: string;
  outputDeviceName?: string;
  systemAudioStatus?: "unverified" | "granted" | "silent_or_denied" | "tap_failed" | string;
  lastError?: string;
  protocolVersion: number;
  dataDir: string;
}

export interface PermissionSnapshot {
  mic: "granted" | "denied" | "not_determined" | "restricted" | string;
  systemAudio: string;
  otherAudioPlaying?: boolean;
  tapReady?: boolean;
}

export interface PermissionRequestResult {
  prompting: boolean;
  restarted?: boolean;
  probeOutcome?: string;
  permissions: PermissionSnapshot;
}

export interface HealthResponse {
  ok: boolean;
  protocolVersion: number;
  appVersion: string;
  pid: number;
  dataDir: string;
  state: string;
  binaryId?: string;
}

export type DaemonProbeResult =
  | { kind: "running"; snapshot: RecorderStateSnapshot }
  | { kind: "not_running" }
  | { kind: "unknown"; error: string };

export class DaemonRequestError extends Error {
  status: number;
  payload: Record<string, unknown>;

  constructor(status: number, message: string, payload: Record<string, unknown> = {}) {
    super(message);
    this.name = "DaemonRequestError";
    this.status = status;
    this.payload = payload;
  }
}

export class DaemonMismatchError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "DaemonMismatchError";
  }
}

export class RecorderDaemonClient {
  private readonly config: ServerConfig;
  private startingPromise: Promise<HealthResponse> | null = null;

  constructor(config: ServerConfig) {
    this.config = config;
  }

  private requestJson<T>(
    method: "GET" | "POST",
    reqPath: string,
    body?: unknown,
    timeoutMs = 15_000,
  ): Promise<T> {
    return new Promise((resolve, reject) => {
      const payload = body !== undefined ? Buffer.from(JSON.stringify(body), "utf8") : undefined;
      const headers: Record<string, string | number> = {
        Accept: "application/json",
      };
      if (payload) {
        headers["Content-Type"] = "application/json";
        headers["Content-Length"] = payload.byteLength;
      }

      const toError = (err: unknown): Error =>
        err instanceof Error ? err : new Error(String(err));
      const connResetErr = (msg: string): NodeJS.ErrnoException => {
        const err = new Error(msg) as NodeJS.ErrnoException;
        err.code = "ECONNRESET";
        return err;
      };
      const timeoutErr = (): NodeJS.ErrnoException => {
        const err = new Error(`Timeout talking to MeetingRecorder at ${this.config.socketPath}`) as NodeJS.ErrnoException;
        err.code = "ETIMEDOUT";
        return err;
      };

      let settled = false;
      let hasResponse = false;
      let ended = false;
      let req: http.ClientRequest;

      const timer = setTimeout(() => {
        const err = timeoutErr();
        finishReject(err);
        req.destroy(err);
      }, timeoutMs);
      timer.unref?.();

      const finishResolve = (val: T) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(val);
      };

      const finishReject = (err: Error) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        reject(err);
      };

      req = http.request(
        {
          socketPath: this.config.socketPath,
          path: reqPath,
          method,
          headers,
          timeout: timeoutMs,
        },
        (res) => {
          hasResponse = true;
          const MAX_RESPONSE_BYTES = 4 * 1024 * 1024;
          const chunks: Buffer[] = [];
          let totalBytes = 0;

          res.on("data", (chunk: Buffer) => {
            if (settled) return;
            totalBytes += chunk.byteLength;
            if (totalBytes > MAX_RESPONSE_BYTES) {
              const err = new Error(`Recorder daemon response exceeded ${MAX_RESPONSE_BYTES} bytes limit`);
              finishReject(err);
              req.destroy(err);
              return;
            }
            chunks.push(chunk);
          });

          res.on("end", () => {
            ended = true;
            if (settled) return;
            try {
              if (!res.complete) {
                finishReject(connResetErr("Recorder daemon connection closed before response completed"));
                return;
              }
              const raw = Buffer.concat(chunks).toString("utf8");
              let parsedValue: unknown = {};
              let parsedRawInvalid = false;
              if (raw.trim().length > 0) {
                try {
                  parsedValue = JSON.parse(raw) as unknown;
                } catch {
                  parsedValue = { raw };
                  parsedRawInvalid = true;
                }
              }
              const isPlainObj =
                !parsedRawInvalid &&
                parsedValue !== null &&
                typeof parsedValue === "object" &&
                !Array.isArray(parsedValue);
              const parsedObj: Record<string, unknown> = isPlainObj
                ? (parsedValue as Record<string, unknown>)
                : { value: parsedValue };
              const status = res.statusCode ?? 500;
              if (status >= 200 && status < 300) {
                if (raw.trim().length === 0 || !isPlainObj) {
                  finishReject(
                    new DaemonRequestError(
                      status,
                      `Recorder daemon returned invalid or empty JSON object payload (${status})`,
                      parsedObj,
                    ),
                  );
                } else {
                  finishResolve(parsedObj as T);
                }
              } else {
                const msg =
                  typeof parsedObj.error === "string"
                    ? parsedObj.error
                    : `Recorder daemon error (${status})`;
                finishReject(new DaemonRequestError(status, msg, parsedObj));
              }
            } catch (err) {
              finishReject(toError(err));
            }
          });

          res.on("aborted", () => {
            finishReject(connResetErr("Recorder daemon response aborted before completion"));
          });

          res.on("error", (err) => {
            finishReject(toError(err));
          });

          res.on("close", () => {
            if (!settled && (!ended || !res.complete)) {
              finishReject(connResetErr("Recorder daemon response stream closed unexpectedly"));
            }
          });
        },
      );

      req.on("timeout", () => {
        const err = timeoutErr();
        finishReject(err);
        req.destroy(err);
      });
      req.on("error", (err) => {
        finishReject(toError(err));
      });
      req.on("close", () => {
        if (!settled && !hasResponse) {
          finishReject(connResetErr("Recorder daemon socket closed before response headers arrived"));
        }
      });

      if (payload) {
        req.write(payload);
      }
      req.end();
    });
  }

  async getHealth(): Promise<HealthResponse> {
    return this.requestJson<HealthResponse>("GET", "/v1/health", undefined, 1000);
  }

  private assertDataDirSafe(requireExisting = false): void {
    try {
      const lst = fs.lstatSync(this.config.dataDir);
      if (lst.isSymbolicLink() || !lst.isDirectory()) {
        throw new Error(`数据目录非法（不允许符号链接）: ${this.config.dataDir}`);
      }
    } catch (err) {
      const code = (err as NodeJS.ErrnoException | undefined)?.code;
      if (code === "ENOENT" && !requireExisting) {
        return;
      }
      throw err;
    }
  }

  async probeStatus(): Promise<DaemonProbeResult> {
    if (process.platform !== "darwin") {
      return { kind: "not_running" };
    }
    try {
      this.assertDataDirSafe(false);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      return { kind: "unknown", error: message };
    }
    if (!fs.existsSync(this.config.socketPath)) {
      return { kind: "not_running" };
    }
    try {
      const snapshot = await this.requestJson<RecorderStateSnapshot>(
        "GET",
        "/v1/sessions/status",
        undefined,
        1200,
      );
      if (
        snapshot.protocolVersion !== 1 ||
        typeof snapshot.dataDir !== "string" ||
        path.resolve(snapshot.dataDir) !== path.resolve(this.config.dataDir)
      ) {
        return {
          kind: "unknown",
          error: `MeetingRecorder 实例协议或数据目录不匹配 (${String(snapshot.dataDir ?? "")})`,
        };
      }
      if (!isValidRecorderState(snapshot.state)) {
        return {
          kind: "unknown",
          error: `MeetingRecorder 守护进程返回非法或缺失的 state 字段 (${String(snapshot.state ?? "")})`,
        };
      }
      return { kind: "running", snapshot };
    } catch (err) {
      const code = (err as NodeJS.ErrnoException | undefined)?.code;
      if (code === "ENOENT" || code === "ECONNREFUSED") {
        return { kind: "not_running" };
      }
      const message = err instanceof Error ? err.message : String(err);
      return { kind: "unknown", error: message };
    }
  }

  async tryGetPermissionsIfRunning(): Promise<PermissionSnapshot | null> {
    if (process.platform !== "darwin") {
      return null;
    }
    try {
      this.assertDataDirSafe(false);
    } catch {
      return null;
    }
    if (!fs.existsSync(this.config.socketPath)) {
      return null;
    }
    try {
      return await this.requestJson<PermissionSnapshot>("GET", "/v1/permissions", undefined, 1200);
    } catch {
      return null;
    }
  }

  async ensureRunning(): Promise<HealthResponse> {
    if (this.startingPromise) {
      return this.startingPromise;
    }
    const p = this.doEnsureRunning().finally(() => {
      if (this.startingPromise === p) {
        this.startingPromise = null;
      }
    });
    this.startingPromise = p;
    return p;
  }

  private currentBundleBinaryId(): string | null {
    const exePath = path.join(this.config.resolveAppBundlePath(), "Contents", "MacOS", "MeetingRecorder");
    try {
      const st = fs.statSync(exePath);
      if (!st.isFile()) return null;
      return `${st.dev}:${st.ino}`;
    } catch {
      return null;
    }
  }

  private isStaleDaemon(health: HealthResponse): boolean {
    const expected = this.currentBundleBinaryId();
    if (!expected) {
      return false;
    }
    return health.appVersion !== "0.4.0" || health.binaryId !== expected;
  }

  private async quitIfIdleAndWait(): Promise<boolean> {
    try {
      const health = await this.getHealth();
      this.assertHealthMatches(health);
      if (health.state !== "idle" && health.state !== "error") {
        return false;
      }
    } catch (err) {
      const code = (err as NodeJS.ErrnoException | undefined)?.code;
      if (code === "ENOENT" || code === "ECONNREFUSED") {
        return true;
      }
      throw err;
    }

    await this.requestJson("POST", "/v1/app/quit", {}, 1500).catch(() => {});

    const deadline = Date.now() + 2500;
    while (Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 120));
      try {
        await this.getHealth();
      } catch (err) {
        const code = (err as NodeJS.ErrnoException | undefined)?.code;
        if (code === "ENOENT" || code === "ECONNREFUSED") {
          return true;
        }
      }
    }
    return !fs.existsSync(this.config.socketPath);
  }

  private async doEnsureRunning(): Promise<HealthResponse> {
    if (process.platform !== "darwin") {
      throw new Error("Meeting Notes audio recording is currently supported on macOS only.");
    }
    this.assertDataDirSafe(false);
    let retiredStaleDaemon = false;
    try {
      const health = await this.getHealth();
      this.assertHealthMatches(health);
      if (
        this.isStaleDaemon(health) &&
        (health.state === "idle" || health.state === "error")
      ) {
        retiredStaleDaemon = await this.quitIfIdleAndWait();
      }
      if (!retiredStaleDaemon) {
        return health;
      }
    } catch (err) {
      const code = (err as NodeJS.ErrnoException | undefined)?.code;
      if (code !== "ENOENT" && code !== "ECONNREFUSED") {
        throw err;
      }
    }

    const appBundlePath = this.config.resolveAppBundlePath();
    if (!fs.existsSync(appBundlePath)) {
      throw new Error(
        `MeetingRecorder.app is not initialized yet (${appBundlePath}). Click "Initialize Local Recorder" in the Meeting Notes panel first.`,
      );
    }

    this.assertDataDirSafe(false);
    fs.mkdirSync(this.config.dataDir, { recursive: true });
    this.assertDataDirSafe(true);
    fs.mkdirSync(path.dirname(this.config.socketPath), { recursive: true });

    await execFileAsync(
      "open",
      [
        "-n",
        "-g",
        "-a",
        appBundlePath,
        "--args",
        "--data-dir",
        this.config.dataDir,
        "--socket",
        this.config.socketPath,
      ],
      { timeout: 5_000 },
    );

    const deadline = Date.now() + 7000;
    let lastErr: unknown;
    while (Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 200));
      try {
        const health = await this.getHealth();
        this.assertHealthMatches(health);
        return health;
      } catch (err) {
        if (err instanceof DaemonMismatchError) {
          throw err;
        }
        lastErr = err;
      }
    }

    const detail = lastErr instanceof Error ? lastErr.message : String(lastErr ?? "");
    throw new Error(`无法连接 MeetingRecorder.app (${this.config.socketPath}): ${detail}`);
  }

  private assertHealthMatches(health: HealthResponse): void {
    if (!health.ok) {
      throw new DaemonMismatchError("MeetingRecorder health check returned ok=false");
    }
    if (health.protocolVersion !== 1) {
      throw new DaemonMismatchError(
        `MeetingRecorder protocolVersion 不匹配: expected 1, got ${health.protocolVersion}`,
      );
    }
    const expectedDir = path.resolve(this.config.dataDir);
    const actualDir = path.resolve(health.dataDir);
    if (expectedDir !== actualDir) {
      throw new DaemonMismatchError(
        `已有 MeetingRecorder 实例指向不同数据目录 (${actualDir} != ${expectedDir})，请先退出旧的 MeetingRecorder 实例后再试。`,
      );
    }
  }

  async getPermissions(): Promise<PermissionSnapshot> {
    await this.ensureRunning();
    return this.requestJson<PermissionSnapshot>("GET", "/v1/permissions");
  }

  async requestPermission(
    kind: "mic" | "systemAudio" = "mic",
    openSettings = false,
  ): Promise<PermissionRequestResult> {
    await this.ensureRunning();
    return this.requestJson<PermissionRequestResult>("POST", "/v1/permissions/request", {
      kind,
      openSettings,
    });
  }

  async restartIfIdle(): Promise<{
    restarted: boolean;
    snapshot: RecorderStateSnapshot;
    permissions: PermissionSnapshot;
  }> {
    this.assertDataDirSafe(false);
    let stopped = false;
    try {
      const health = await this.getHealth();
      this.assertHealthMatches(health);
      if (health.state !== "idle" && health.state !== "error") {
        throw new Error("当前正在录制或封包中，暂不能重启采集服务。");
      }
      stopped = await this.quitIfIdleAndWait();
      if (!stopped) {
        throw new Error("旧版或当前采集进程未能退出，请稍后重试。");
      }
    } catch (err) {
      const code = (err as NodeJS.ErrnoException | undefined)?.code;
      if (code !== "ENOENT" && code !== "ECONNREFUSED") {
        throw err;
      }
      stopped = true;
    }
    const snapshot = await this.getStatus();
    const permissions = await this.getPermissions();
    return { restarted: stopped, snapshot, permissions };
  }

  async getStatus(): Promise<RecorderStateSnapshot> {
    await this.ensureRunning();
    const res = await this.requestJson<RecorderStateSnapshot>("GET", "/v1/sessions/status");
    if (!isValidRecorderState(res.state)) {
      throw new DaemonRequestError(
        200,
        "Recorder daemon returned incomplete or invalid session snapshot state",
        res as unknown as Record<string, unknown>,
      );
    }
    return res;
  }

  async startSession(params: {
    mode?: "mic" | "dual" | string;
    title?: string;
    idempotencyKey?: string;
    chunkSec?: number;
    appTarget?: string;
  }): Promise<RecorderStateSnapshot> {
    await this.ensureRunning();
    const res = await this.requestJson<RecorderStateSnapshot>(
      "POST",
      "/v1/sessions/start",
      params,
      15_000,
    );
    if (!isValidRecorderState(res.state)) {
      throw new DaemonRequestError(
        200,
        "Recorder daemon returned incomplete or invalid session snapshot state",
        res as unknown as Record<string, unknown>,
      );
    }
    return res;
  }

  async stopSession(meetingId?: string): Promise<{
    snapshot: RecorderStateSnapshot;
    manifest?: MeetingManifest;
  }> {
    await this.ensureRunning();
    const res = await this.requestJson<{
      snapshot: RecorderStateSnapshot;
      manifest?: MeetingManifest;
    }>("POST", "/v1/sessions/stop", meetingId ? { meetingId } : {}, 30_000);
    const snap = res.snapshot as unknown;
    if (
      !snap ||
      typeof snap !== "object" ||
      Array.isArray(snap) ||
      !isValidRecorderState((snap as Record<string, unknown>).state)
    ) {
      throw new DaemonRequestError(
        200,
        "Recorder daemon returned incomplete stop response payload",
        res as unknown as Record<string, unknown>,
      );
    }
    return res;
  }
}
