import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { build } from "esbuild";

const here = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(here, "../..");
const nativeEntry = path.join(rootDir, "mcp-server/src/native.ts");
const storeEntry = path.join(rootDir, "mcp-server/src/store.ts");

const stamp = `${process.pid}-${Date.now()}`;
const tempNativeBundle = path.join(os.tmpdir(), `meeting-notes-native-test-${stamp}.mjs`);
const tempStoreBundle = path.join(os.tmpdir(), `meeting-notes-store-test-${stamp}.mjs`);
const tempWorkDir = fs.mkdtempSync(path.join(os.tmpdir(), "meeting-notes-fallback-work-"));

try {
  await Promise.all([
    build({
      entryPoints: [nativeEntry],
      bundle: true,
      format: "esm",
      platform: "node",
      target: ["node22"],
      outfile: tempNativeBundle,
    }),
    build({
      entryPoints: [storeEntry],
      bundle: true,
      format: "esm",
      platform: "node",
      target: ["node22"],
      outfile: tempStoreBundle,
    }),
  ]);

  const { createJsFallbackBinding, decodeSwiftUint64Js } = await import(
    `${pathToFileURL(tempNativeBundle).href}?t=${stamp}`
  );
  const { MeetingStore } = await import(`${pathToFileURL(tempStoreBundle).href}?t=${stamp}`);

  let passed = 0;
  function test(name, fn) {
    fn();
    passed += 1;
    console.log(`PASS: ${name}`);
  }

  test("decodeSwiftUint64Js parses integers, scientific notation, and rejects invalid/overflow", () => {
    assert.equal(decodeSwiftUint64Js("0"), "0");
    assert.equal(decodeSwiftUint64Js("-0"), "0");
    assert.equal(decodeSwiftUint64Js("42"), "42");
    assert.equal(decodeSwiftUint64Js("1.23e+18"), "1230000000000000000");
    assert.equal(decodeSwiftUint64Js("9.223372036854775807e18"), "9223372036854775807");
    assert.equal(decodeSwiftUint64Js("18446744073709551615"), "18446744073709551615");
    assert.equal(decodeSwiftUint64Js("18446744073709551616"), null);
    assert.equal(decodeSwiftUint64Js("-1"), null);
    assert.equal(decodeSwiftUint64Js("1.5"), null);
    assert.equal(decodeSwiftUint64Js("NaN"), null);
    assert.equal(decodeSwiftUint64Js(""), null);
  });

  test("JS fallback openDir & openat enforce symlink ELOOP and traversal EINVAL", () => {
    const binding = createJsFallbackBinding();
    const dir = path.join(tempWorkDir, "openat-dir");
    fs.mkdirSync(dir, { recursive: true });
    const filePath = path.join(dir, "hello.txt");
    fs.writeFileSync(filePath, "hello-fallback", "utf8");
    const linkPath = path.join(dir, "link.txt");
    fs.symlinkSync(filePath, linkPath);
    const dirLink = path.join(tempWorkDir, "dir-link");
    fs.symlinkSync(dir, dirLink);

    assert.throws(() => binding.openDir(dirLink, binding.O_RDONLY | binding.O_DIRECTORY), {
      code: "ELOOP",
    });

    const dirfd = binding.openDir(dir, binding.O_RDONLY | binding.O_DIRECTORY);
    try {
      const fd = binding.openat(
        dirfd,
        "hello.txt",
        binding.O_RDONLY | binding.O_NOFOLLOW | binding.O_NONBLOCK,
      );
      try {
        assert.equal(fs.readFileSync(fd, "utf8"), "hello-fallback");
      } finally {
        fs.closeSync(fd);
      }

      assert.throws(() => binding.openat(dirfd, "link.txt", binding.O_RDONLY | binding.O_NOFOLLOW), {
        code: "ELOOP",
      });
      assert.throws(() => binding.openat(dirfd, "../x", binding.O_RDONLY), {
        code: "EINVAL",
      });
      assert.throws(() => binding.openat(dirfd, "a/b", binding.O_RDONLY), {
        code: "EINVAL",
      });
      assert.throws(() => binding.openat(dirfd, ".", binding.O_RDONLY), {
        code: "EINVAL",
      });
      assert.throws(() => binding.openat(dirfd, "..", binding.O_RDONLY), {
        code: "EINVAL",
      });
    } finally {
      fs.closeSync(dirfd);
    }
  });

  test("JS fallback renamex_excl enforces EEXIST and renamex_swap preserves inodes", () => {
    const binding = createJsFallbackBinding();
    const exclSrc = path.join(tempWorkDir, "excl-src.txt");
    const exclDst = path.join(tempWorkDir, "excl-dst.txt");
    const existingDst = path.join(tempWorkDir, "excl-existing.txt");
    fs.writeFileSync(exclSrc, "src-data", "utf8");
    fs.writeFileSync(existingDst, "keep-existing", "utf8");

    assert.throws(() => binding.renamex_excl(exclSrc, existingDst), { code: "EEXIST" });
    assert.equal(fs.readFileSync(existingDst, "utf8"), "keep-existing");

    binding.renamex_excl(exclSrc, exclDst);
    assert.equal(fs.existsSync(exclSrc), false);
    assert.equal(fs.readFileSync(exclDst, "utf8"), "src-data");

    const swapA = path.join(tempWorkDir, "swap-a.txt");
    const swapB = path.join(tempWorkDir, "swap-b.txt");
    fs.writeFileSync(swapA, "content-A", "utf8");
    fs.writeFileSync(swapB, "content-B", "utf8");

    const beforeA = fs.lstatSync(swapA);
    const beforeB = fs.lstatSync(swapB);
    binding.renamex_swap(swapA, swapB);
    const afterA = fs.lstatSync(swapA);
    const afterB = fs.lstatSync(swapB);

    assert.equal(fs.readFileSync(swapA, "utf8"), "content-B");
    assert.equal(fs.readFileSync(swapB, "utf8"), "content-A");
    assert.equal(afterA.ino, beforeB.ino);
    assert.equal(afterB.ino, beforeA.ino);
  });

  test("MeetingStore settings default to English and preserve sibling keys on partial updates", () => {
    const dataDir = path.join(tempWorkDir, "store-data");
    const store = new MeetingStore(path.join(dataDir, "meetings"), dataDir);

    assert.deepEqual(store.getSettings(), {
      audioRetentionPolicy: "manual",
      uiLanguage: "en",
    });

    const afterLang = store.setSettings({ uiLanguage: "zh" });
    assert.deepEqual(afterLang, {
      audioRetentionPolicy: "manual",
      uiLanguage: "zh",
    });

    const afterPolicy = store.setSettings({ audioRetentionPolicy: "days_7" });
    assert.deepEqual(afterPolicy, {
      audioRetentionPolicy: "days_7",
      uiLanguage: "zh",
    });

    assert.deepEqual(store.getSettings(), {
      audioRetentionPolicy: "days_7",
      uiLanguage: "zh",
    });
  });

  console.log(`\nAll ${passed} native-fallback & settings test suites passed.`);
} finally {
  fs.rmSync(tempNativeBundle, { force: true });
  fs.rmSync(tempStoreBundle, { force: true });
  fs.rmSync(tempWorkDir, { recursive: true, force: true });
}
