import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

export interface ServerConfig {
  dataDir: string;
  meetingsDir: string;
  pluginRoot: string;
  recorderSourcesDir: string;
  nativeSourcesDir: string;
  dataBinDir: string;
  dataAppBundlePath: string;
  pluginAppBundlePath: string;
  readonly appBundlePath: string;
  resolveAppBundlePath(): string;
  socketPath: string;
  uiHtmlPath: string;
}

function parseArg(argv: string[], flag: string): string | undefined {
  for (let i = 0; i < argv.length; i++) {
    const item = argv[i];
    if (item === flag && i + 1 < argv.length) {
      return argv[i + 1];
    }
    if (item.startsWith(`${flag}=`)) {
      return item.slice(flag.length + 1);
    }
  }
  return undefined;
}

export function resolveSocketPath(dataDir: string, explicitSocket?: string): string {
  const candidate = explicitSocket
    ? path.resolve(explicitSocket)
    : path.join(dataDir, "run", "recorder.sock");
  if (Buffer.byteLength(candidate, "utf8") < 100) {
    return candidate;
  }
  const uid = typeof process.getuid === "function" ? process.getuid() : 0;
  const privateDir = path.join("/tmp", `meeting-notes-${uid}`);
  fs.mkdirSync(privateDir, { recursive: true, mode: 0o700 });
  try {
    fs.chmodSync(privateDir, 0o700);
  } catch {
    // Ignore if already restricted.
  }
  const hash = crypto.createHash("sha256").update(candidate).digest("hex").slice(0, 12);
  return path.join(privateDir, `s-${hash}.sock`);
}

function hasExecutable(appDir: string): boolean {
  try {
    const exePath = path.join(appDir, "Contents", "MacOS", "MeetingRecorder");
    return fs.statSync(exePath).isFile();
  } catch {
    return false;
  }
}

export function loadConfig(argv: string[] = process.argv.slice(2)): ServerConfig {
  const here = path.dirname(fileURLToPath(import.meta.url));
  const defaultPluginRoot = path.resolve(here, "..");
  const defaultDataDir = path.join(
    os.homedir(),
    "Library",
    "Application Support",
    "MeetingNotes",
  );

  const rawDataDir =
    parseArg(argv, "--data-dir") ||
    process.env.MEETING_DATA_DIR ||
    process.env.PLUGIN_DATA ||
    defaultDataDir;

  const rawPluginRoot =
    parseArg(argv, "--plugin-root") ||
    process.env.PLUGIN_ROOT ||
    defaultPluginRoot;

  const dataDir = path.resolve(rawDataDir);
  const pluginRoot = path.resolve(rawPluginRoot);
  const explicitSocket = parseArg(argv, "--socket");

  const bundledRecorderSources = path.join(pluginRoot, "sources", "recorder-macos");
  const devRecorderSources = path.resolve(pluginRoot, "..", "recorder-macos");
  const recorderSourcesDir = fs.existsSync(path.join(bundledRecorderSources, "Package.swift"))
    ? bundledRecorderSources
    : fs.existsSync(path.join(devRecorderSources, "Package.swift"))
      ? devRecorderSources
      : bundledRecorderSources;

  const bundledNativeSources = path.join(pluginRoot, "sources", "native");
  const devNativeSources = path.resolve(pluginRoot, "..", "mcp-server", "native");
  const nativeSourcesDir = fs.existsSync(path.join(bundledNativeSources, "safe_openat.c"))
    ? bundledNativeSources
    : fs.existsSync(path.join(devNativeSources, "safe_openat.c"))
      ? devNativeSources
      : bundledNativeSources;

  const dataBinDir = path.join(dataDir, "bin");
  const dataAppBundlePath = path.join(dataBinDir, "MeetingRecorder.app");
  const pluginAppBundlePath = path.join(pluginRoot, "bin", "MeetingRecorder.app");

  const resolveAppBundlePath = (): string => {
    if (hasExecutable(dataAppBundlePath)) {
      return dataAppBundlePath;
    }
    if (hasExecutable(pluginAppBundlePath)) {
      return pluginAppBundlePath;
    }
    return dataAppBundlePath;
  };

  return {
    dataDir,
    meetingsDir: path.join(dataDir, "meetings"),
    pluginRoot,
    recorderSourcesDir,
    nativeSourcesDir,
    dataBinDir,
    dataAppBundlePath,
    pluginAppBundlePath,
    get appBundlePath() {
      return resolveAppBundlePath();
    },
    resolveAppBundlePath,
    socketPath: resolveSocketPath(dataDir, explicitSocket),
    uiHtmlPath:
      process.env.MEETING_APP_HTML || path.join(pluginRoot, "ui", "app.html"),
  };
}
