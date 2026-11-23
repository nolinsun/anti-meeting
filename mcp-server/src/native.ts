import fs from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

export interface SafeOpenatBinding {
  openat(dirfd: number, name: string, flags: number, mode?: number): number;
  flock(fd: number, operation: number): void;
  renamex_excl(fromPath: string, toPath: string): void;
  renamex_swap(fromPath: string, toPath: string): void;
  decode_swift_uint64(token: string): string | null;
  O_RDONLY: number;
  O_NOFOLLOW: number;
  O_DIRECTORY: number;
  O_NONBLOCK: number;
  O_CLOEXEC: number;
  LOCK_EX: number;
  LOCK_SH: number;
  LOCK_NB: number;
  LOCK_UN: number;
}

export function loadSafeOpenatBinding(): SafeOpenatBinding {
  const req = createRequire(import.meta.url);
  const here = path.dirname(fileURLToPath(import.meta.url));
  const candidates = [
    path.join(here, "safe_openat.node"),
    path.resolve(here, "../native/safe_openat.node"),
    path.resolve(here, "../../plugin/bin/safe_openat.node"),
    ...(process.env.ANTIGRAVITY_PLUGIN_ROOT
      ? [path.join(process.env.ANTIGRAVITY_PLUGIN_ROOT, "bin", "safe_openat.node")]
      : []),
    path.resolve(process.cwd(), "plugin", "bin", "safe_openat.node"),
  ];
  for (const candidate of candidates) {
    if (!fs.existsSync(candidate)) continue;
    const loaded = req(candidate) as SafeOpenatBinding;
    if (
      loaded &&
      typeof loaded.openat === "function" &&
      typeof loaded.flock === "function" &&
      typeof loaded.renamex_excl === "function" &&
      typeof loaded.renamex_swap === "function" &&
      typeof loaded.decode_swift_uint64 === "function"
    ) {
      return loaded;
    }
  }
  throw new Error(
    `无法加载原生安全打开模块 safe_openat.node（已搜索：${candidates.join(", ")}）`,
  );
}

export const safeOpenat = loadSafeOpenatBinding();
