import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

export interface ServerConfig {
  dataDir: string;
  meetingsDir: string;
  pluginRoot: string;
  appBundlePath: string;
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
  const privateDir = path.join("/tmp", `agy-meeting-${uid}`);
  fs.mkdirSync(privateDir, { recursive: true, mode: 0o700 });
  try {
    fs.chmodSync(privateDir, 0o700);
  } catch {
    // Ignore if already restricted.
  }
  const hash = crypto.createHash("sha256").update(candidate).digest("hex").slice(0, 12);
  return path.join(privateDir, `s-${hash}.sock`);
}

export function loadConfig(argv: string[] = process.argv.slice(2)): ServerConfig {
  const here = path.dirname(fileURLToPath(import.meta.url));
  const defaultPluginRoot = path.resolve(here, "..");
  const defaultDataDir = path.join(
    os.homedir(),
    "Library",
    "Application Support",
    "AntiMeeting",
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

  return {
    dataDir,
    meetingsDir: path.join(dataDir, "meetings"),
    pluginRoot,
    appBundlePath: path.join(pluginRoot, "bin", "MeetingRecorder.app"),
    socketPath: resolveSocketPath(dataDir, explicitSocket),
    uiHtmlPath:
      process.env.MEETING_APP_HTML || path.join(pluginRoot, "ui", "app.html"),
  };
}
