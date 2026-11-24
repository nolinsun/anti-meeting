import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(here, "..");

const srcRecorderDir = path.join(rootDir, "recorder-macos");
const dstRecorderDir = path.join(rootDir, "plugin", "sources", "recorder-macos");

const srcNativeDir = path.join(rootDir, "mcp-server", "native");
const dstNativeDir = path.join(rootDir, "plugin", "sources", "native");

const SKIP_DIRS = new Set([".build", ".git", "node_modules"]);
const SKIP_FILES = new Set([".DS_Store"]);

function copyFilteredDir(srcDir, dstDir) {
  fs.mkdirSync(dstDir, { recursive: true });
  const entries = fs.readdirSync(srcDir, { withFileTypes: true });
  for (const entry of entries) {
    if (entry.isDirectory()) {
      if (SKIP_DIRS.has(entry.name)) continue;
      copyFilteredDir(path.join(srcDir, entry.name), path.join(dstDir, entry.name));
    } else if (entry.isFile()) {
      if (SKIP_FILES.has(entry.name)) continue;
      const srcFile = path.join(srcDir, entry.name);
      const dstFile = path.join(dstDir, entry.name);
      fs.copyFileSync(srcFile, dstFile);
      if (entry.name.endsWith(".sh")) {
        fs.chmodSync(dstFile, 0o755);
      }
    }
  }
}

fs.rmSync(dstRecorderDir, { recursive: true, force: true });
fs.mkdirSync(dstRecorderDir, { recursive: true });
fs.copyFileSync(
  path.join(srcRecorderDir, "Package.swift"),
  path.join(dstRecorderDir, "Package.swift"),
);
copyFilteredDir(path.join(srcRecorderDir, "Sources"), path.join(dstRecorderDir, "Sources"));
copyFilteredDir(path.join(srcRecorderDir, "scripts"), path.join(dstRecorderDir, "scripts"));

fs.rmSync(dstNativeDir, { recursive: true, force: true });
fs.mkdirSync(dstNativeDir, { recursive: true });
for (const name of ["safe_openat.c", "swift_u64.swift", "build-openat.sh"]) {
  const srcFile = path.join(srcNativeDir, name);
  const dstFile = path.join(dstNativeDir, name);
  fs.copyFileSync(srcFile, dstFile);
  if (name.endsWith(".sh")) {
    fs.chmodSync(dstFile, 0o755);
  }
}

console.log(`[sync-plugin-sources] Synced recorder-macos & native sources -> plugin/sources/`);
