import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const here = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(here, "../..");
const entryTs = path.join(rootDir, "ui/src/app.ts");
const cssPath = path.join(rootDir, "ui/src/styles.css");
const outHtml = path.join(rootDir, "plugin/ui/app.html");

const result = await build({
  entryPoints: [entryTs],
  bundle: true,
  write: false,
  format: "iife",
  platform: "browser",
  target: ["es2022"],
  minify: true,
});

const jsCode = result.outputFiles[0]?.text ?? "";
const cssCode = fs.readFileSync(cssPath, "utf8");

const html = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>anti-meeting</title>
  <style>
${cssCode}
  </style>
</head>
<body>
  <div id="root"></div>
  <script>
${jsCode}
  </script>
</body>
</html>
`;

fs.mkdirSync(path.dirname(outHtml), { recursive: true });
fs.writeFileSync(outHtml, html, "utf8");
const sizeKb = (Buffer.byteLength(html, "utf8") / 1024).toFixed(1);
console.log(`[build-ui] Wrote ${outHtml} (${sizeKb} KB)`);
