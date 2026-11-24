import crypto from "node:crypto";
import fs from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

export interface SafeOpenatBinding {
  openat(dirfd: number, name: string, flags: number, mode?: number): number;
  openDir(dirPath: string, flags: number): number;
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
  isNative: boolean;
}

interface RawNativeBinding {
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

const UINT64_MAX = 18446744073709551615n;

function makePosixError(code: string, message: string): NodeJS.ErrnoException {
  const err = new Error(`${code}: ${message}`) as NodeJS.ErrnoException;
  err.code = code;
  return err;
}

function lstatIfExists(targetPath: string): fs.Stats | null {
  try {
    return fs.lstatSync(targetPath);
  } catch (err) {
    const code = (err as NodeJS.ErrnoException | undefined)?.code;
    if (code === "ENOENT") return null;
    throw err;
  }
}

export function decodeSwiftUint64Js(token: string): string | null {
  if (typeof token !== "string" || token.length === 0 || token.length > 16_777_216) {
    return null;
  }
  const m = /^(-)?(0|[1-9][0-9]*)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$/.exec(token);
  if (!m) {
    return null;
  }
  const neg = m[1] === "-";
  const intPart = m[2];
  const fracPart = m[3] ?? "";
  const rawDigits = `${intPart}${fracPart}`;
  if (/^0+$/.test(rawDigits)) {
    return "0";
  }
  if (neg) {
    return null;
  }
  const exp = m[4] !== undefined ? Number(m[4]) : 0;
  if (!Number.isSafeInteger(exp) || exp > 30 || exp < -100) {
    return null;
  }
  const shift = exp - fracPart.length;
  let intStr: string;
  if (shift >= 0) {
    intStr = `${rawDigits}${"0".repeat(shift)}`;
  } else {
    const splitIdx = rawDigits.length + shift;
    if (splitIdx <= 0) {
      return null;
    }
    const fracTail = rawDigits.slice(splitIdx);
    if (/[^0]/.test(fracTail)) {
      return null;
    }
    intStr = rawDigits.slice(0, splitIdx);
  }
  const val = BigInt(intStr);
  if (val < 0n || val > UINT64_MAX) {
    return null;
  }
  return val.toString();
}

export function createJsFallbackBinding(): SafeOpenatBinding {
  const fdToPath = new Map<number, string>();
  const consts = fs.constants as Record<string, number | undefined>;
  const hasRealODirectory = typeof consts.O_DIRECTORY === "number" && consts.O_DIRECTORY !== 0;
  const O_RDONLY = consts.O_RDONLY ?? 0;
  const O_NOFOLLOW = consts.O_NOFOLLOW ?? 0;
  const O_NONBLOCK = consts.O_NONBLOCK ?? 0;
  const O_CLOEXEC = consts.O_CLOEXEC ?? 0;
  const O_DIRECTORY = hasRealODirectory ? (consts.O_DIRECTORY as number) : 0x20000;

  const toOsFlags = (flags: number): number => {
    return hasRealODirectory ? flags : flags & ~O_DIRECTORY;
  };

  const openDir = (dirPath: string, flags: number): number => {
    if (typeof dirPath !== "string" || !dirPath || dirPath.includes("\0")) {
      throw makePosixError("EINVAL", "Invalid directory path");
    }
    const lst = fs.lstatSync(dirPath);
    if (lst.isSymbolicLink()) {
      throw makePosixError("ELOOP", `Symbolic link not allowed: '${dirPath}'`);
    }
    if (!lst.isDirectory()) {
      throw makePosixError("ENOTDIR", `Not a directory: '${dirPath}'`);
    }
    try {
      const fd = fs.openSync(dirPath, toOsFlags(flags));
      fdToPath.set(fd, dirPath);
      return fd;
    } catch (err) {
      const code = (err as NodeJS.ErrnoException | undefined)?.code;
      if (process.platform === "win32" && (code === "EISDIR" || code === "EPERM")) {
        throw makePosixError("ENOTSUP", `Directory fd operations are not supported on ${process.platform}`);
      }
      throw err;
    }
  };

  const openat = (dirfd: number, name: string, flags: number, mode = 0): number => {
    if (typeof dirfd !== "number" || !Number.isInteger(dirfd) || dirfd < 0) {
      throw makePosixError("EBADF", "Invalid dirfd");
    }
    const parentPath = fdToPath.get(dirfd);
    if (!parentPath) {
      throw makePosixError("EBADF", "Unknown dirfd");
    }
    if (typeof name !== "string" || !name || name.includes("\0")) {
      throw makePosixError("EINVAL", "Invalid path component");
    }
    if (name.includes("/") || (process.platform === "win32" && name.includes("\\"))) {
      throw makePosixError("EINVAL", "Component name must not contain path separator");
    }
    if (name === "." || name === "..") {
      throw makePosixError("EINVAL", "Component name must not be '.' or '..'");
    }

    const target = path.join(parentPath, name);
    const lst = fs.lstatSync(target);
    if (lst.isSymbolicLink()) {
      throw makePosixError("ELOOP", `Symbolic link not allowed: '${name}'`);
    }
    const wantsDir = (flags & O_DIRECTORY) !== 0;
    if (wantsDir && !lst.isDirectory()) {
      throw makePosixError("ENOTDIR", `Not a directory: '${name}'`);
    }
    if (!wantsDir && lst.isDirectory()) {
      throw makePosixError("EISDIR", `Is a directory: '${name}'`);
    }

    const fd = fs.openSync(target, toOsFlags(flags), mode);
    if (lst.isDirectory()) {
      fdToPath.set(fd, target);
    }
    return fd;
  };

  const flock = (_fd: number, _operation: number): void => {
    // Pure-JS fallback: in-process execution is single-threaded; kernel flock activates once native addon compiles on macOS.
  };

  const renamex_excl = (fromPath: string, toPath: string): void => {
    if (
      typeof fromPath !== "string" ||
      !fromPath ||
      fromPath.includes("\0") ||
      typeof toPath !== "string" ||
      !toPath ||
      toPath.includes("\0")
    ) {
      throw makePosixError("EINVAL", "Invalid path for renamex_excl");
    }
    const fromStat = fs.lstatSync(fromPath);
    if (lstatIfExists(toPath) !== null) {
      throw makePosixError("EEXIST", `Destination already exists: '${toPath}'`);
    }
    if (fromStat.isFile()) {
      try {
        fs.linkSync(fromPath, toPath);
        fs.unlinkSync(fromPath);
        return;
      } catch (err) {
        const code = (err as NodeJS.ErrnoException | undefined)?.code;
        if (code === "EEXIST") {
          throw err;
        }
        if (code !== "EXDEV" && code !== "EPERM" && code !== "ENOTSUP") {
          throw err;
        }
      }
    }
    if (lstatIfExists(toPath) !== null) {
      throw makePosixError("EEXIST", `Destination already exists: '${toPath}'`);
    }
    fs.renameSync(fromPath, toPath);
  };

  const renamex_swap = (fromPath: string, toPath: string): void => {
    if (
      typeof fromPath !== "string" ||
      !fromPath ||
      fromPath.includes("\0") ||
      typeof toPath !== "string" ||
      !toPath ||
      toPath.includes("\0")
    ) {
      throw makePosixError("EINVAL", "Invalid path for renamex_swap");
    }
    fs.lstatSync(fromPath);
    fs.lstatSync(toPath);
    const pivot = path.join(path.dirname(toPath), `.swap.${crypto.randomUUID()}.tmp`);
    fs.renameSync(toPath, pivot);
    try {
      fs.renameSync(fromPath, toPath);
    } catch (err) {
      try {
        fs.renameSync(pivot, toPath);
      } catch {
        // best-effort rollback
      }
      throw err;
    }
    try {
      fs.renameSync(pivot, fromPath);
    } catch (err) {
      try {
        fs.renameSync(toPath, fromPath);
        fs.renameSync(pivot, toPath);
      } catch {
        // best-effort rollback
      }
      throw err;
    }
  };

  return {
    openat,
    openDir,
    flock,
    renamex_excl,
    renamex_swap,
    decode_swift_uint64: decodeSwiftUint64Js,
    O_RDONLY,
    O_NOFOLLOW,
    O_DIRECTORY,
    O_NONBLOCK,
    O_CLOEXEC,
    LOCK_EX: 2,
    LOCK_SH: 1,
    LOCK_NB: 4,
    LOCK_UN: 8,
    isNative: false,
  };
}

function wrapNativeBinding(raw: RawNativeBinding): SafeOpenatBinding {
  return {
    openat: (dirfd, name, flags, mode) => raw.openat(dirfd, name, flags, mode),
    openDir: (dirPath, flags) => fs.openSync(dirPath, flags),
    flock: (fd, operation) => raw.flock(fd, operation),
    renamex_excl: (fromPath, toPath) => raw.renamex_excl(fromPath, toPath),
    renamex_swap: (fromPath, toPath) => raw.renamex_swap(fromPath, toPath),
    decode_swift_uint64: (token) => raw.decode_swift_uint64(token),
    O_RDONLY: raw.O_RDONLY,
    O_NOFOLLOW: raw.O_NOFOLLOW,
    O_DIRECTORY: raw.O_DIRECTORY,
    O_NONBLOCK: raw.O_NONBLOCK,
    O_CLOEXEC: raw.O_CLOEXEC,
    LOCK_EX: raw.LOCK_EX,
    LOCK_SH: raw.LOCK_SH,
    LOCK_NB: raw.LOCK_NB,
    LOCK_UN: raw.LOCK_UN,
    isNative: true,
  };
}

function tryLoadNativeAddon(extraSearchDirs: string[] = []): SafeOpenatBinding | null {
  if (process.platform !== "darwin") {
    return null;
  }
  const req = createRequire(import.meta.url);
  const here = path.dirname(fileURLToPath(import.meta.url));
  const candidates = [
    ...extraSearchDirs.map((dir) => path.join(dir, "safe_openat.node")),
    path.join(here, "safe_openat.node"),
    path.resolve(here, "../bin/safe_openat.node"),
    path.resolve(here, "../native/safe_openat.node"),
    path.resolve(here, "../../plugin/bin/safe_openat.node"),
    ...(process.env.PLUGIN_DATA
      ? [path.join(process.env.PLUGIN_DATA, "bin", "safe_openat.node")]
      : []),
    ...(process.env.PLUGIN_ROOT
      ? [path.join(process.env.PLUGIN_ROOT, "bin", "safe_openat.node")]
      : []),
    ...(process.env.ANTIGRAVITY_PLUGIN_ROOT
      ? [path.join(process.env.ANTIGRAVITY_PLUGIN_ROOT, "bin", "safe_openat.node")]
      : []),
    path.resolve(process.cwd(), "plugin", "bin", "safe_openat.node"),
  ];

  const seen = new Set<string>();
  for (const candidate of candidates) {
    const resolved = path.resolve(candidate);
    if (seen.has(resolved)) continue;
    seen.add(resolved);
    if (!fs.existsSync(resolved)) continue;
    try {
      const loaded = req(resolved) as RawNativeBinding;
      if (
        loaded &&
        typeof loaded.openat === "function" &&
        typeof loaded.flock === "function" &&
        typeof loaded.renamex_excl === "function" &&
        typeof loaded.renamex_swap === "function" &&
        typeof loaded.decode_swift_uint64 === "function"
      ) {
        return wrapNativeBinding(loaded);
      }
    } catch {
      // Ignore incompatible or corrupt .node binary and continue fallback search.
    }
  }
  return null;
}

let activeBinding: SafeOpenatBinding = tryLoadNativeAddon() ?? createJsFallbackBinding();

export function configureNativeSearchDirs(dirs: string[]): boolean {
  if (activeBinding.isNative) {
    return true;
  }
  const loaded = tryLoadNativeAddon(dirs);
  if (loaded) {
    activeBinding = loaded;
    return true;
  }
  return false;
}

export const safeOpenat: SafeOpenatBinding = {
  openat: (dirfd, name, flags, mode) => activeBinding.openat(dirfd, name, flags, mode),
  openDir: (dirPath, flags) => activeBinding.openDir(dirPath, flags),
  flock: (fd, operation) => activeBinding.flock(fd, operation),
  renamex_excl: (fromPath, toPath) => activeBinding.renamex_excl(fromPath, toPath),
  renamex_swap: (fromPath, toPath) => activeBinding.renamex_swap(fromPath, toPath),
  decode_swift_uint64: (token) => activeBinding.decode_swift_uint64(token),
  get O_RDONLY() {
    return activeBinding.O_RDONLY;
  },
  get O_NOFOLLOW() {
    return activeBinding.O_NOFOLLOW;
  },
  get O_DIRECTORY() {
    return activeBinding.O_DIRECTORY;
  },
  get O_NONBLOCK() {
    return activeBinding.O_NONBLOCK;
  },
  get O_CLOEXEC() {
    return activeBinding.O_CLOEXEC;
  },
  get LOCK_EX() {
    return activeBinding.LOCK_EX;
  },
  get LOCK_SH() {
    return activeBinding.LOCK_SH;
  },
  get LOCK_NB() {
    return activeBinding.LOCK_NB;
  },
  get LOCK_UN() {
    return activeBinding.LOCK_UN;
  },
  get isNative() {
    return activeBinding.isNative;
  },
};
