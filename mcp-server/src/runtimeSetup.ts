import { execFile } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import type { ServerConfig } from "./config.js";
import { configureNativeSearchDirs, safeOpenat } from "./native.js";

const execFileAsync = promisify(execFile);

export const RUNTIME_APP_VERSION = "0.4.0";
const BUNDLE_ID = "io.github.nolinsun.meeting-recorder";

export interface RuntimeStatus {
  platform: NodeJS.Platform;
  supported: boolean;
  appReady: boolean;
  needsRebuild: boolean;
  sourcesAvailable: boolean;
  hasSwiftToolchain: boolean;
  nativeAddonLoaded: boolean;
  building: boolean;
  buildStage: string | null;
  lastBuildError: string | null;
}

interface RuntimeStamp {
  version: string;
  fingerprint: string;
  builtAt: string;
}

let activeBuildPromise: Promise<RuntimeStatus> | null = null;
let currentBuildStage: string | null = null;
let lastBuildError: string | null = null;
let cachedToolchainAvailable: boolean | null = null;

function isAppExecutableReady(appDir: string): boolean {
  try {
    const exePath = path.join(appDir, "Contents", "MacOS", "MeetingRecorder");
    return fs.statSync(exePath).isFile();
  } catch {
    return false;
  }
}

function assertSafeDataDir(dataDir: string): void {
  try {
    const lst = fs.lstatSync(dataDir);
    if (lst.isSymbolicLink() || !lst.isDirectory()) {
      throw new Error(`Invalid data directory (symlinks not allowed): ${dataDir}`);
    }
  } catch (err) {
    const code = (err as NodeJS.ErrnoException | undefined)?.code;
    if (code === "ENOENT") {
      fs.mkdirSync(dataDir, { recursive: true });
      const after = fs.lstatSync(dataDir);
      if (after.isSymbolicLink() || !after.isDirectory()) {
        throw new Error(`Invalid data directory (symlinks not allowed): ${dataDir}`);
      }
      return;
    }
    throw err;
  }
}

function collectSourceFiles(baseDir: string, currentDir: string, out: string[]): void {
  const entries = fs.readdirSync(currentDir, { withFileTypes: true });
  entries.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  for (const entry of entries) {
    if (entry.name === ".build" || entry.name === ".git" || entry.name === ".DS_Store") continue;
    const full = path.join(currentDir, entry.name);
    if (entry.isDirectory()) {
      collectSourceFiles(baseDir, full, out);
    } else if (
      entry.isFile() &&
      (entry.name === "Package.swift" || entry.name.endsWith(".swift"))
    ) {
      out.push(path.relative(baseDir, full));
    }
  }
}

function computeRecorderFingerprint(recorderSourcesDir: string): string | null {
  const pkgPath = path.join(recorderSourcesDir, "Package.swift");
  if (!fs.existsSync(pkgPath)) {
    return null;
  }
  const files: string[] = [];
  collectSourceFiles(recorderSourcesDir, recorderSourcesDir, files);
  files.sort();
  const hash = crypto.createHash("sha256");
  hash.update(RUNTIME_APP_VERSION);
  for (const rel of files) {
    hash.update("\0");
    hash.update(rel);
    hash.update("\0");
    hash.update(fs.readFileSync(path.join(recorderSourcesDir, rel)));
  }
  return hash.digest("hex");
}

function readRuntimeStamp(dataBinDir: string): RuntimeStamp | null {
  const stampPath = path.join(dataBinDir, ".runtime-version.json");
  try {
    const lst = fs.lstatSync(stampPath);
    if (lst.isSymbolicLink() || !lst.isFile()) return null;
    const parsed = JSON.parse(fs.readFileSync(stampPath, "utf8")) as Partial<RuntimeStamp>;
    if (
      parsed &&
      typeof parsed.version === "string" &&
      typeof parsed.fingerprint === "string" &&
      typeof parsed.builtAt === "string"
    ) {
      return parsed as RuntimeStamp;
    }
  } catch {
    // Missing or unreadable stamp.
  }
  return null;
}

async function detectSwiftToolchain(forceRefresh = false): Promise<boolean> {
  if (process.platform !== "darwin") {
    return false;
  }
  if (cachedToolchainAvailable !== null && !forceRefresh) {
    return cachedToolchainAvailable;
  }
  try {
    await execFileAsync("swift", ["--version"], { timeout: 5_000 });
    await execFileAsync("which", ["codesign"], { timeout: 5_000 });
    cachedToolchainAvailable = true;
  } catch {
    cachedToolchainAvailable = false;
  }
  return cachedToolchainAvailable;
}

async function resolveSigningIdentity(): Promise<string> {
  try {
    const { stdout } = await execFileAsync(
      "security",
      ["find-identity", "-v", "-p", "codesigning"],
      { timeout: 5_000 },
    );
    if (stdout.includes('"Local Meeting Recorder"')) {
      return "Local Meeting Recorder";
    }
  } catch {
    // Fallback to ad-hoc signing.
  }
  return "-";
}

function findNodeIncludeDir(): string | null {
  const candidates = [
    path.resolve(path.dirname(process.execPath), "../include/node"),
    "/opt/homebrew/include/node",
    "/usr/local/include/node",
  ];
  for (const dir of candidates) {
    if (fs.existsSync(path.join(dir, "node_api.h"))) {
      return dir;
    }
  }
  return null;
}

async function tryBuildNativeAddon(config: ServerConfig): Promise<void> {
  const cPath = path.join(config.nativeSourcesDir, "safe_openat.c");
  const swiftPath = path.join(config.nativeSourcesDir, "swift_u64.swift");
  if (!fs.existsSync(cPath) || !fs.existsSync(swiftPath)) {
    return;
  }
  const nodeInc = findNodeIncludeDir();
  if (!nodeInc) {
    return;
  }
  const outPath = path.join(config.dataBinDir, "safe_openat.node");
  const tmpObj = path.join(os.tmpdir(), `safe_openat_${process.pid}_${Date.now()}.o`);
  const stagedOut = path.join(config.dataBinDir, `.safe_openat.${process.pid}.${Date.now()}.node.tmp`);
  try {
    await execFileAsync("cc", ["-c", "-fPIC", "-O2", "-I", nodeInc, cPath, "-o", tmpObj], {
      timeout: 30_000,
    });
    await execFileAsync(
      "swiftc",
      [
        "-O",
        "-parse-as-library",
        "-emit-library",
        swiftPath,
        tmpObj,
        "-Xlinker",
        "-undefined",
        "-Xlinker",
        "dynamic_lookup",
        "-o",
        stagedOut,
      ],
      { timeout: 45_000 },
    );
    await execFileAsync("codesign", ["--force", "--sign", "-", stagedOut], {
      timeout: 15_000,
    }).catch(() => {});
    fs.renameSync(stagedOut, outPath);
    configureNativeSearchDirs([config.dataBinDir]);
  } catch {
    // Best-effort acceleration: pure-JS fallback remains active if native headers/compiler fail.
  } finally {
    try {
      fs.rmSync(tmpObj, { force: true });
    } catch {
      // ignore
    }
    try {
      fs.rmSync(stagedOut, { force: true });
    } catch {
      // ignore
    }
  }
}

export async function getRuntimeStatus(config: ServerConfig): Promise<RuntimeStatus> {
  const supported = process.platform === "darwin";
  const dataReady = isAppExecutableReady(config.dataAppBundlePath);
  const pluginReady = isAppExecutableReady(config.pluginAppBundlePath);
  const appReady = supported && (dataReady || pluginReady);
  const fingerprint = computeRecorderFingerprint(config.recorderSourcesDir);
  const sourcesAvailable = fingerprint !== null;

  let needsRebuild = !appReady;
  if (appReady && dataReady && fingerprint) {
    const stamp = readRuntimeStamp(config.dataBinDir);
    if (!stamp || stamp.version !== RUNTIME_APP_VERSION || stamp.fingerprint !== fingerprint) {
      needsRebuild = true;
    }
  }

  const hasSwiftToolchain = await detectSwiftToolchain(false);
  return {
    platform: process.platform,
    supported,
    appReady,
    needsRebuild,
    sourcesAvailable,
    hasSwiftToolchain,
    nativeAddonLoaded: safeOpenat.isNative,
    building: activeBuildPromise !== null,
    buildStage: currentBuildStage,
    lastBuildError,
  };
}

function copyRecorderSources(srcDir: string, dstDir: string): void {
  fs.rmSync(dstDir, { recursive: true, force: true });
  fs.mkdirSync(dstDir, { recursive: true });
  fs.cpSync(path.join(srcDir, "Package.swift"), path.join(dstDir, "Package.swift"));
  fs.cpSync(path.join(srcDir, "Sources"), path.join(dstDir, "Sources"), { recursive: true });
}

function renderInfoPlist(): string {
  return `<?xml version="1.0" encoding="UTF-8"?>
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
  <string>${RUNTIME_APP_VERSION}</string>
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
`;
}

async function performLocalBuild(config: ServerConfig): Promise<RuntimeStatus> {
  if (process.platform !== "darwin") {
    const msg = "Local audio recording is supported on macOS only.";
    lastBuildError = msg;
    throw new Error(msg);
  }

  lastBuildError = null;
  currentBuildStage = "Checking Swift toolchain...";
  const hasToolchain = await detectSwiftToolchain(true);
  if (!hasToolchain) {
    const msg =
      "Xcode Command Line Tools are required to compile the local macOS recorder. Run `xcode-select --install` in Terminal and try again.";
    lastBuildError = msg;
    throw new Error(msg);
  }

  const fingerprint = computeRecorderFingerprint(config.recorderSourcesDir);
  if (!fingerprint) {
    const msg = `Bundled recorder sources not found at ${config.recorderSourcesDir}`;
    lastBuildError = msg;
    throw new Error(msg);
  }

  assertSafeDataDir(config.dataDir);
  fs.mkdirSync(config.dataBinDir, { recursive: true });

  const buildRoot = path.join(config.dataDir, "build");
  const stagedSources = path.join(buildRoot, "recorder-macos");
  const scratchPath = path.join(buildRoot, ".swift-build");
  fs.mkdirSync(buildRoot, { recursive: true });

  currentBuildStage = "Staging Swift recorder sources...";
  copyRecorderSources(config.recorderSourcesDir, stagedSources);

  currentBuildStage = "Compiling MeetingRecorder (Swift release)...";
  const swiftArgs = [
    "build",
    "-c",
    "release",
    "--disable-sandbox",
    "--scratch-path",
    scratchPath,
  ];
  await execFileAsync("swift", swiftArgs, {
    cwd: stagedSources,
    timeout: 180_000,
    maxBuffer: 8 * 1024 * 1024,
  });

  const { stdout: binDirRaw } = await execFileAsync(
    "swift",
    [...swiftArgs, "--show-bin-path"],
    { cwd: stagedSources, timeout: 15_000 },
  );
  const compiledBin = path.join(binDirRaw.trim(), "MeetingRecorder");
  if (!fs.existsSync(compiledBin)) {
    throw new Error(`Compiled MeetingRecorder binary missing at ${compiledBin}`);
  }

  currentBuildStage = "Packaging & signing MeetingRecorder.app...";
  const stagingApp = path.join(config.dataBinDir, `.MeetingRecorder.app.staging.${process.pid}`);
  fs.rmSync(stagingApp, { recursive: true, force: true });
  fs.mkdirSync(path.join(stagingApp, "Contents", "MacOS"), { recursive: true });
  fs.mkdirSync(path.join(stagingApp, "Contents", "Resources"), { recursive: true });
  fs.copyFileSync(compiledBin, path.join(stagingApp, "Contents", "MacOS", "MeetingRecorder"));
  fs.chmodSync(path.join(stagingApp, "Contents", "MacOS", "MeetingRecorder"), 0o755);
  fs.writeFileSync(path.join(stagingApp, "Contents", "Info.plist"), renderInfoPlist(), "utf8");

  const signIdentity = await resolveSigningIdentity();
  await execFileAsync(
    "codesign",
    ["--force", "--deep", "--sign", signIdentity, "--identifier", BUNDLE_ID, stagingApp],
    { timeout: 30_000 },
  );

  fs.rmSync(config.dataAppBundlePath, { recursive: true, force: true });
  fs.renameSync(stagingApp, config.dataAppBundlePath);

  currentBuildStage = "Compiling native helper (optional)...";
  await tryBuildNativeAddon(config);

  const stampTmp = path.join(config.dataBinDir, `.runtime-version.${process.pid}.tmp`);
  const stamp: RuntimeStamp = {
    version: RUNTIME_APP_VERSION,
    fingerprint,
    builtAt: new Date().toISOString(),
  };
  fs.writeFileSync(stampTmp, `${JSON.stringify(stamp, null, 2)}\n`, "utf8");
  fs.renameSync(stampTmp, path.join(config.dataBinDir, ".runtime-version.json"));

  currentBuildStage = null;
  lastBuildError = null;
  return getRuntimeStatus(config);
}

export async function buildLocalRuntime(config: ServerConfig): Promise<RuntimeStatus> {
  if (activeBuildPromise) {
    return activeBuildPromise;
  }
  activeBuildPromise = performLocalBuild(config)
    .catch((err) => {
      lastBuildError = err instanceof Error ? err.message : String(err);
      throw err;
    })
    .finally(() => {
      activeBuildPromise = null;
      currentBuildStage = null;
    });
  return activeBuildPromise;
}
