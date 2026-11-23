import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { build } from "esbuild";

const here = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(here, "../..");
const markdownEntry = path.join(rootDir, "ui/src/markdown.ts");
const tempBundlePath = path.join("/tmp", "anti-meeting-markdown-test.mjs");

await build({
  entryPoints: [markdownEntry],
  bundle: true,
  format: "esm",
  platform: "neutral",
  target: ["es2022"],
  outfile: tempBundlePath,
});

const { escapeHtml, renderMarkdown } = await import(`${pathToFileURL(tempBundlePath).href}?t=${Date.now()}`);

let passed = 0;
function test(name, fn) {
  fn();
  passed += 1;
  console.log(`PASS: ${name}`);
}

test("empty and whitespace inputs", () => {
  assert.equal(renderMarkdown(""), `<div class="empty-state">暂无内容</div>`);
  assert.equal(renderMarkdown("   \n\t\n  "), `<div class="empty-state">暂无内容</div>`);
});

test("headings H1-H6 and trailing hashes", () => {
  const md = [
    "# H1 Title",
    "## H2 Title ##",
    "### H3 C#",
    "#### H4",
    "##### H5",
    "###### H6",
  ].join("\n");
  const out = renderMarkdown(md);
  assert.match(out, /<h1>H1 Title<\/h1>/);
  assert.match(out, /<h2>H2 Title<\/h2>/);
  assert.match(out, /<h3>H3 C#<\/h3>/);
  assert.match(out, /<h4>H4<\/h4>/);
  assert.match(out, /<h5>H5<\/h5>/);
  assert.match(out, /<h6>H6<\/h6>/);
});

test("all 5 GFM alert types with default and custom titles", () => {
  const md = [
    "> [!NOTE]",
    "> Default note **body**",
    "",
    "> [!TIP] 实用建议",
    "> Use `chunk_001`",
    "",
    "> [!IMPORTANT]",
    "> - item 1",
    "> - item 2",
    "",
    "> [!WARNING] 无有效语音内容",
    "> 峰值振幅为 0",
    "",
    "> [!CAUTION]",
    "> Danger ahead",
  ].join("\n");
  const out = renderMarkdown(md);
  assert.match(out, /<div class="md-alert md-alert-note" role="note">.*<span>备注<\/span>.*<strong>body<\/strong>/s);
  assert.match(out, /<div class="md-alert md-alert-tip" role="note">.*<span>实用建议<\/span>.*<code>chunk_001<\/code>/s);
  assert.match(out, /<div class="md-alert md-alert-important" role="note">.*<span>重要<\/span>.*<ul><li>item 1<\/li><li>item 2<\/li><\/ul>/s);
  assert.match(out, /<div class="md-alert md-alert-warning" role="note">.*<span>无有效语音内容<\/span>.*峰值振幅为 0/s);
  assert.match(out, /<div class="md-alert md-alert-caution" role="note">.*<span>警示<\/span>.*Danger ahead/s);
});

test("standard and nested blockquotes", () => {
  const md = [
    "> Outer quote",
    "> > Inner quote with `code`",
  ].join("\n");
  const out = renderMarkdown(md);
  assert.match(out, /<blockquote><p>Outer quote<\/p>\n<blockquote><p>Inner quote with <code>code<\/code><\/p><\/blockquote><\/blockquote>/);
});

test("GFM tables with alignment, escaped pipes, code pipes, and ragged rows", () => {
  const md = [
    "## Action Items",
    "| 事项 | 负责人 | 截止时间 |",
    "| :--- | :---: | ---: |",
    "| 核查 `a|b` 接口 | 张三 \\| 李四 | 2026-11-30 |",
    "| 补齐字段 | 王五 |",
    "| 多余列 | 赵六 | 周五 | extra |",
  ].join("\n");
  const out = renderMarkdown(md);
  assert.match(out, /<h2>Action Items<\/h2>/);
  assert.match(out, /<div class="md-table-wrap"><table><thead><tr>/);
  assert.match(out, /<th style="text-align:left">事项<\/th>/);
  assert.match(out, /<th style="text-align:center">负责人<\/th>/);
  assert.match(out, /<th style="text-align:right">截止时间<\/th>/);
  assert.match(out, /<td style="text-align:left">核查 <code>a\|b<\/code> 接口<\/td>/);
  assert.match(out, /<td style="text-align:center">张三 \| 李四<\/td>/);
  assert.match(out, /<td style="text-align:left">补齐字段<\/td><td style="text-align:center">王五<\/td><td style="text-align:right"><\/td>/);
  assert.doesNotMatch(out, /extra/);
});

test("unordered, ordered, nested mixed, and task lists", () => {
  const md = [
    "- item A",
    "  * sub A1",
    "  3. sub A2",
    "+ item B",
    "",
    "3. step three",
    "4. step four",
    "",
    "- [ ] todo task",
    "- [x] done task",
  ].join("\n");
  const out = renderMarkdown(md);
  assert.match(out, /<ul><li>item A<ul><li>sub A1<\/li><\/ul><ol start="3"><li>sub A2<\/li><\/ol><\/li><li>item B<\/li><\/ul>/);
  assert.match(out, /<ol start="3"><li>step three<\/li><li>step four<\/li><\/ol>/);
  assert.match(out, /<ul class="md-task-list"><li class="md-task-item"><input type="checkbox" class="md-task-checkbox" disabled \/><span>todo task<\/span><\/li><li class="md-task-item"><input type="checkbox" class="md-task-checkbox" disabled checked \/><span>done task<\/span><\/li><\/ul>/);
});

test("fenced code blocks preserve raw HTML and markdown", () => {
  const md = [
    "```json",
    "{\"a\": \"<b>**not bold**</b>\"}",
    "```",
    "",
    "~~~",
    "<script>alert(1)</script>",
    "# not heading",
    "~~~",
  ].join("\n");
  const out = renderMarkdown(md);
  assert.match(out, /<div class="md-code-block"><div class="md-code-lang">json<\/div><pre><code class="language-json">\{&quot;a&quot;: &quot;&lt;b&gt;\*\*not bold\*\*&lt;\/b&gt;&quot;\}<\/code><\/pre><\/div>/);
  assert.match(out, /<pre><code>&lt;script&gt;alert\(1\)&lt;\/script&gt;\n# not heading<\/code><\/pre>/);
  assert.doesNotMatch(out, /<script>/);
});

test("horizontal rules", () => {
  const out = renderMarkdown("---\n\n***\n\n___");
  assert.equal(out, "<hr />\n<hr />\n<hr />");
});

test("inline emphasis, double-backticks, and snake_case preservation", () => {
  const md = "**bold** *italic* ***both*** ~~del~~ `` `**raw**` `` `chunk_001` snake_case_var _em_ __strong__";
  const out = renderMarkdown(md);
  assert.match(out, /<strong>bold<\/strong>/);
  assert.match(out, /<em>italic<\/em>/);
  assert.match(out, /<strong><em>both<\/em><\/strong>/);
  assert.match(out, /<del>del<\/del>/);
  assert.match(out, /<code>`\*\*raw\*\*`<\/code>/);
  assert.match(out, /<code>chunk_001<\/code>/);
  assert.match(out, /snake_case_var/);
  assert.match(out, /<em>em<\/em>/);
  assert.match(out, /<strong>strong<\/strong>/);
  assert.doesNotMatch(out, /snake<em>case<\/em>var/);
});

test("links with query params, parens, autolinks, and XSS defenses", () => {
  const md = [
    "[Docs](https://example.com/a_(b)?x=1&y=2 \"My & Title\")",
    "[`code_link`](https://example.com/path)",
    "<https://a.com?k=1&v=2> and <https://b.com>",
    "[bad js](javascript:alert(1))",
    "[bad data](data:text/html,<script>alert(1)</script>)",
    "<script>alert(1)</script><img src=x onerror=alert(1)>",
    "nul\u0000byte",
  ].join("\n");
  const out = renderMarkdown(md);
  assert.match(out, /<a class="md-link" href="https:\/\/example\.com\/a_\(b\)\?x=1&amp;y=2" target="_blank" rel="noopener noreferrer" title="My &amp; Title">Docs<\/a>/);
  assert.match(out, /<a class="md-link" href="https:\/\/example\.com\/path" target="_blank" rel="noopener noreferrer"><code>code_link<\/code><\/a>/);
  assert.match(out, /<a class="md-link" href="https:\/\/a\.com\?k=1&amp;v=2" target="_blank" rel="noopener noreferrer">https:\/\/a\.com\?k=1&amp;v=2<\/a> and <a class="md-link" href="https:\/\/b\.com" target="_blank" rel="noopener noreferrer">https:\/\/b\.com<\/a>/);
  assert.doesNotMatch(out, /javascript:/i);
  assert.doesNotMatch(out, /data:text\/html/i);
  assert.doesNotMatch(out, /<script>/i);
  assert.doesNotMatch(out, /<img/i);
  assert.match(out, /&lt;img src=x onerror=alert\(1\)&gt;/);
  assert.equal(out.includes("\u0000"), false);
  assert.equal(escapeHtml(`a&b<c>"'`), "a&amp;b&lt;c&gt;&quot;&#39;");
});

test("sample meeting notes and transcript fixtures render cleanly", () => {
  const sampleNotesWithCustomAlert = [
    "> [!WARNING] 部分完成",
    "> 本场录制包含 1 处声轨缺口（`00:12`–`00:18`），其余内容已完整整理。",
    "",
    "## 一句话概要",
    "",
    "本次双轨会议明确了新版接口上线节奏与负责人安排。",
    "",
    "## 行动项（Action Items）",
    "",
    "| 事项 | 负责人 | 截止时间 |",
    "| :--- | :--- | :--- |",
    "| 补充接口压测报告 | 我方 | 周五 18:00 |",
    "| 确认灰度白名单 | 对方 | 下周一 |",
  ].join("\n");

  const notes1 = renderMarkdown(sampleNotesWithCustomAlert);
  assert.match(notes1, /<div class="md-alert md-alert-warning" role="note">/);
  assert.match(notes1, /<span>部分完成<\/span>/);
  assert.match(notes1, /<table><thead><tr><th style="text-align:left">事项<\/th><th style="text-align:left">负责人<\/th><th style="text-align:left">截止时间<\/th><\/tr><\/thead><tbody>/);
  assert.doesNotMatch(notes1, /> \[!WARNING\]/);
  assert.doesNotMatch(notes1, /\| :--- \|/);

  const sampleNotesCompactHeading = [
    "> [!WARNING]",
    "> 短时测试录音未检测到有效人声。",
    "",
    "## 行动项（Action Items）",
    "| 事项 | 负责人 | 截止时间 |",
    "| :--- | :--- | :--- |",
    "| 无 | — | — |",
  ].join("\n");

  const notes2 = renderMarkdown(sampleNotesCompactHeading);
  assert.match(notes2, /<div class="md-alert md-alert-warning" role="note">/);
  assert.match(notes2, /<span>注意<\/span>/);
  assert.match(notes2, /<table><thead>/);
  assert.doesNotMatch(notes2, /> \[!WARNING\]/);
  assert.doesNotMatch(notes2, /\| :--- \|/);

  const sampleTranscript = [
    "# 会议逐字稿：项目同步会",
    "",
    "- **会议 ID**：`sample_meeting_001`",
    "- **录制模式**：双轨（`dual`，含混音 / 我方 / 对方分轨与说话人时间线）",
    "",
    "---",
    "",
    "[00:00 – 00:08] **我方**：本周先把接口联调与压测跑通。",
    "[00:08 – 00:15] **对方**：收到，下周一前确认灰度名单。",
  ].join("\n");

  const transcript = renderMarkdown(sampleTranscript);
  assert.match(transcript, /<h1>会议逐字稿：项目同步会<\/h1>/);
  assert.match(transcript, /<ul><li><strong>会议 ID<\/strong>：<code>sample_meeting_001<\/code><\/li>/);
  assert.match(transcript, /<hr \/>/);
  assert.match(transcript, /\[00:00 – 00:08\] <strong>我方<\/strong>/);
  assert.match(transcript, /\[00:08 – 00:15\] <strong>对方<\/strong>/);
});

console.log(`\nAll ${passed} Markdown test suites passed.`);
