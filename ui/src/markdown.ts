export function escapeHtml(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

type AlertType = "note" | "tip" | "important" | "warning" | "caution";

const ALERT_DEFAULTS: Record<AlertType, string> = {
  note: "备注",
  tip: "建议",
  important: "重要",
  warning: "注意",
  caution: "警示",
};

function alertIconSvg(type: AlertType): string {
  const wrap = (inner: string) =>
    `<svg class="md-alert-icon" viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${inner}</svg>`;
  switch (type) {
    case "note":
      return wrap(
        `<circle cx="8" cy="8" r="6"/><path d="M8 7.2v3.6"/><circle cx="8" cy="4.9" r="0.6" fill="currentColor" stroke="none"/>`,
      );
    case "tip":
      return wrap(
        `<path d="M6 12.2h4"/><path d="M6.6 14h2.8"/><path d="M5.6 10.2c-.8-.6-1.4-1.7-1.4-2.9a3.8 3.8 0 1 1 7.6 0c0 1.2-.6 2.3-1.4 2.9-.4.3-.6.7-.6 1.1v.2H6.2v-.2c0-.4-.2-.8-.6-1.1Z"/>`,
      );
    case "important":
      return wrap(
        `<path d="M2.5 3.5h11a1 1 0 0 1 1 1v7a1 1 0 0 1-1 1H6l-3.5 2V4.5a1 1 0 0 1 1-1Z"/><path d="M8 6.2v3"/><circle cx="8" cy="10.7" r="0.5" fill="currentColor" stroke="none"/>`,
      );
    case "warning":
      return wrap(
        `<path d="M7.15 2.7 1.7 12.2a1 1 0 0 0 .85 1.5h10.9a1 1 0 0 0 .85-1.5L8.85 2.7a1 1 0 0 0-1.7 0Z"/><path d="M8 6.3v3.3"/><circle cx="8" cy="11.5" r="0.6" fill="currentColor" stroke="none"/>`,
      );
    case "caution":
      return wrap(
        `<path d="M5.4 2h5.2l3.4 3.4v5.2L10.6 14H5.4L2 10.6V5.4L5.4 2Z"/><path d="M8 5.2v3.6"/><circle cx="8" cy="11.1" r="0.6" fill="currentColor" stroke="none"/>`,
      );
  }
}

function formatEmphasis(text: string): string {
  let s = text;
  s = s.replace(/~~(?=\S)(.+?)(?<=\S)~~/g, "<del>$1</del>");
  s = s.replace(/\*\*\*(?=\S)(.+?)(?<=\S)\*\*\*/g, "<strong><em>$1</em></strong>");
  s = s.replace(/\*\*(?=\S)(.+?)(?<=\S)\*\*/g, "<strong>$1</strong>");
  s = s.replace(
    /(?<![\p{L}\p{N}_])__(?=\S)(.+?)(?<=\S)__(?![\p{L}\p{N}_])/gu,
    "<strong>$1</strong>",
  );
  s = s.replace(/(?<!\*)\*(?=\S)([^*]+?)(?<=\S)\*(?!\*)/g, "<em>$1</em>");
  s = s.replace(
    /(?<![\p{L}\p{N}_])_(?=\S)([^_]+?)(?<=\S)_(?![\p{L}\p{N}_])/gu,
    "<em>$1</em>",
  );
  return s;
}

function extractInlineCodeSpans(
  raw: string,
  stash: (html: string) => string,
): string {
  let out = "";
  let i = 0;
  while (i < raw.length) {
    if (raw[i] === "\\" && i + 1 < raw.length && (raw[i + 1] === "`" || raw[i + 1] === "\\")) {
      out += raw.slice(i, i + 2);
      i += 2;
      continue;
    }
    if (raw[i] !== "`") {
      out += raw[i];
      i += 1;
      continue;
    }

    let openLen = 0;
    while (i + openLen < raw.length && raw[i + openLen] === "`") {
      openLen += 1;
    }

    let j = i + openLen;
    let closeStart = -1;
    while (j < raw.length) {
      if (raw[j] === "`") {
        let closeLen = 0;
        while (j + closeLen < raw.length && raw[j + closeLen] === "`") {
          closeLen += 1;
        }
        if (closeLen === openLen) {
          closeStart = j;
          break;
        }
        j += closeLen;
      } else {
        j += 1;
      }
    }

    if (closeStart !== -1) {
      let code = raw.slice(i + openLen, closeStart);
      if (code.length >= 2 && code.startsWith(" ") && code.endsWith(" ") && /[^ ]/.test(code)) {
        code = code.slice(1, -1);
      }
      out += stash(`<code>${escapeHtml(code)}</code>`);
      i = closeStart + openLen;
    } else {
      out += raw.slice(i, i + openLen);
      i += openLen;
    }
  }
  return out;
}

function isSafeLinkHref(escapedUrl: string): boolean {
  const unescapedAmp = escapedUrl.replace(/&amp;/g, "&");
  return /^https?:\/\/\S+$/i.test(unescapedAmp) || /^mailto:[^\s@]+@[^\s@]+$/i.test(unescapedAmp);
}

export function formatInline(raw: string): string {
  const tokens: string[] = [];
  const stash = (html: string): string => {
    const idx = tokens.length;
    tokens.push(html);
    return `\u0000T${idx}\u0000`;
  };

  // Pass 1: inline code spans before HTML escaping
  let s = extractInlineCodeSpans(raw, stash);

  // Pass 2: escape HTML
  s = escapeHtml(s);

  // Pass 3: backslash escapes
  s = s.replace(/\\([\\`*_{}[\]()#+\-.!~|])/g, (_, ch: string) => stash(ch));

  // Pass 4: Markdown links & autolinks
  s = s.replace(
    /\[([^\]]+)\]\(([^()\s]+(?:\([^()\s]*\)[^()\s]*)*)(?:\s+&quot;((?:(?!&quot;)[^\n])*)&quot;)?\)/g,
    (_, label: string, url: string, title?: string) => {
      const formattedLabel = formatEmphasis(label);
      if (!isSafeLinkHref(url)) {
        return formattedLabel;
      }
      const titleAttr = title ? ` title="${title}"` : "";
      return stash(
        `<a class="md-link" href="${url}" target="_blank" rel="noopener noreferrer"${titleAttr}>${formattedLabel}</a>`,
      );
    },
  );

  s = s.replace(
    /&lt;(https?:\/\/(?:(?!&gt;|&lt;)\S)+)&gt;/g,
    (_, url: string) => {
      if (!isSafeLinkHref(url)) {
        return `&lt;${url}&gt;`;
      }
      return stash(
        `<a class="md-link" href="${url}" target="_blank" rel="noopener noreferrer">${url}</a>`,
      );
    },
  );

  // Pass 5: emphasis & strikethrough
  s = formatEmphasis(s);

  // Pass 6: restore stashed tokens iteratively (handles code spans inside link labels)
  for (let pass = 0; pass < 5; pass += 1) {
    const next = s.replace(/\u0000T(\d+)\u0000/g, (_, idxStr: string) => {
      return tokens[Number(idxStr)] ?? "";
    });
    if (next === s) break;
    s = next;
  }

  return s;
}

const FENCE_OPEN_RE = /^\s*(`{3,}|~{3,})\s*([^\s`~]*)\s*$/;
const HEADING_RE = /^\s*(#{1,6})\s+(.+?)(?:\s+#+\s*)?$/;
const HR_RE = /^\s*(?:(?:-\s*){3,}|(?:\*\s*){3,}|(?:_\s*){3,})$/;
const BLOCKQUOTE_RE = /^\s*>\s?(.*)$/;
const ALERT_MARKER_RE = /^\s*\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\](?:\s+(.*))?$/i;
const TABLE_DELIM_CELL_RE = /^:?-{1,}:?$/;
const UNORDERED_ITEM_RE = /^[-*+]\s+(.*)$/;
const ORDERED_ITEM_RE = /^(\d{1,9})[.)]\s+(.*)$/;
const TASK_ITEM_RE = /^\[([ xX])\]\s+(.*)$/;

interface ListItemMatch {
  indent: number;
  ordered: boolean;
  start: number;
  content: string;
}

function measureIndent(line: string): number {
  let indent = 0;
  for (const ch of line) {
    if (ch === " ") indent += 1;
    else if (ch === "\t") indent += 2;
    else break;
  }
  return indent;
}

function matchListItem(line: string): ListItemMatch | null {
  if (HR_RE.test(line)) return null;
  const indent = measureIndent(line);
  const rest = line.trimStart();
  const ul = UNORDERED_ITEM_RE.exec(rest);
  if (ul) {
    return { indent, ordered: false, start: 1, content: ul[1] };
  }
  const ol = ORDERED_ITEM_RE.exec(rest);
  if (ol) {
    return { indent, ordered: true, start: Number(ol[1]), content: ol[2] };
  }
  return null;
}

function splitTableRow(line: string): string[] {
  const trimmed = line.trim();
  if (!trimmed) return [];

  const pipePositions: number[] = [];
  let i = 0;
  while (i < trimmed.length) {
    const ch = trimmed[i];
    if (ch === "\\") {
      i += 2;
      continue;
    }
    if (ch === "`") {
      let tickLen = 0;
      while (i + tickLen < trimmed.length && trimmed[i + tickLen] === "`") {
        tickLen += 1;
      }
      let j = i + tickLen;
      let matched = false;
      while (j < trimmed.length) {
        if (trimmed[j] === "`") {
          let closeLen = 0;
          while (j + closeLen < trimmed.length && trimmed[j + closeLen] === "`") {
            closeLen += 1;
          }
          if (closeLen === tickLen) {
            i = j + closeLen;
            matched = true;
            break;
          }
          j += closeLen;
        } else {
          j += 1;
        }
      }
      if (!matched) {
        i += tickLen;
      }
      continue;
    }
    if (ch === "|") {
      pipePositions.push(i);
    }
    i += 1;
  }

  let startOffset = 0;
  let endOffset = trimmed.length;
  let innerPipes = pipePositions;

  if (innerPipes.length > 0 && innerPipes[0] === 0) {
    startOffset = 1;
    innerPipes = innerPipes.slice(1);
  }
  if (innerPipes.length > 0 && innerPipes[innerPipes.length - 1] === trimmed.length - 1) {
    endOffset = trimmed.length - 1;
    innerPipes = innerPipes.slice(0, -1);
  }

  const cells: string[] = [];
  let cursor = startOffset;
  for (const pos of innerPipes) {
    cells.push(trimmed.slice(cursor, pos).trim().replace(/\\\|/g, "|"));
    cursor = pos + 1;
  }
  cells.push(trimmed.slice(cursor, endOffset).trim().replace(/\\\|/g, "|"));
  return cells;
}

type Alignment = "" | "left" | "center" | "right";

function parseTableAlignment(delimCell: string): Alignment {
  const left = delimCell.startsWith(":");
  const right = delimCell.endsWith(":");
  if (left && right) return "center";
  if (right) return "right";
  if (left) return "left";
  return "";
}

function tryMatchTableAt(
  lines: string[],
  index: number,
): { alignments: Alignment[]; headers: string[] } | null {
  if (index + 1 >= lines.length) return null;
  if (!lines[index].includes("|") || !lines[index + 1].includes("|")) return null;
  if (
    FENCE_OPEN_RE.test(lines[index]) ||
    HEADING_RE.test(lines[index]) ||
    BLOCKQUOTE_RE.test(lines[index])
  ) {
    return null;
  }
  const headers = splitTableRow(lines[index]);
  const delims = splitTableRow(lines[index + 1]);
  if (headers.length < 1 || delims.length !== headers.length) return null;
  if (!delims.every((cell) => TABLE_DELIM_CELL_RE.test(cell))) return null;
  return {
    headers,
    alignments: delims.map(parseTableAlignment),
  };
}

function isBlockStarter(lines: string[], index: number): boolean {
  const line = lines[index];
  if (!line.trim()) return true;
  if (FENCE_OPEN_RE.test(line)) return true;
  if (HEADING_RE.test(line)) return true;
  if (HR_RE.test(line)) return true;
  if (BLOCKQUOTE_RE.test(line)) return true;
  if (matchListItem(line) !== null) return true;
  if (tryMatchTableAt(lines, index) !== null) return true;
  return false;
}

function parseList(
  lines: string[],
  startIndex: number,
  baseIndent: number,
  ordered: boolean,
): { html: string; nextIndex: number } {
  const items: string[] = [];
  let i = startIndex;
  let firstStart = 1;
  let hasFirstStart = false;
  let hasTaskItem = false;

  while (i < lines.length) {
    const matched = matchListItem(lines[i]);
    if (!matched || matched.indent < baseIndent || (matched.indent === baseIndent && matched.ordered !== ordered)) {
      break;
    }
    if (matched.indent > baseIndent) {
      break;
    }

    if (!hasFirstStart) {
      firstStart = matched.start;
      hasFirstStart = true;
    }

    const itemTextLines: string[] = [matched.content];
    let nestedHtml = "";
    i += 1;

    while (i < lines.length) {
      const cur = lines[i];
      if (!cur.trim()) {
        let nextNonBlank = i + 1;
        while (nextNonBlank < lines.length && !lines[nextNonBlank].trim()) {
          nextNonBlank += 1;
        }
        if (nextNonBlank >= lines.length) {
          i = nextNonBlank;
          break;
        }
        const nextList = matchListItem(lines[nextNonBlank]);
        if (nextList && nextList.indent > baseIndent) {
          i = nextNonBlank;
          const nested = parseList(lines, i, nextList.indent, nextList.ordered);
          nestedHtml += nested.html;
          i = nested.nextIndex;
          continue;
        }
        if (nextList && nextList.indent === baseIndent && nextList.ordered === ordered) {
          i = nextNonBlank;
          break;
        }
        break;
      }

      if (
        FENCE_OPEN_RE.test(cur) ||
        HEADING_RE.test(cur) ||
        HR_RE.test(cur) ||
        BLOCKQUOTE_RE.test(cur) ||
        tryMatchTableAt(lines, i) !== null
      ) {
        break;
      }

      const sub = matchListItem(cur);
      if (sub) {
        if (sub.indent > baseIndent) {
          const nested = parseList(lines, i, sub.indent, sub.ordered);
          nestedHtml += nested.html;
          i = nested.nextIndex;
          continue;
        }
        break;
      }

      itemTextLines.push(cur.trim());
      i += 1;
    }

    let taskChecked: boolean | null = null;
    if (!ordered && itemTextLines.length > 0) {
      const taskMatch = TASK_ITEM_RE.exec(itemTextLines[0]);
      if (taskMatch) {
        hasTaskItem = true;
        taskChecked = taskMatch[1].toLowerCase() === "x";
        itemTextLines[0] = taskMatch[2];
      }
    }

    const bodyHtml = itemTextLines.map((lineText) => formatInline(lineText)).join("<br />");
    if (taskChecked !== null) {
      items.push(
        `<li class="md-task-item"><input type="checkbox" class="md-task-checkbox" disabled${taskChecked ? " checked" : ""} /><span>${bodyHtml}</span>${nestedHtml}</li>`,
      );
    } else {
      items.push(`<li>${bodyHtml}${nestedHtml}</li>`);
    }
  }

  if (ordered) {
    const startAttr = firstStart !== 1 ? ` start="${firstStart}"` : "";
    return { html: `<ol${startAttr}>${items.join("")}</ol>`, nextIndex: i };
  }
  const classAttr = hasTaskItem ? ` class="md-task-list"` : "";
  return { html: `<ul${classAttr}>${items.join("")}</ul>`, nextIndex: i };
}

function renderBlocks(lines: string[]): string {
  const html: string[] = [];
  let i = 0;

  while (i < lines.length) {
    const line = lines[i];
    if (!line.trim()) {
      i += 1;
      continue;
    }

    // 1. Fenced code blocks
    const fenceOpen = FENCE_OPEN_RE.exec(line);
    if (fenceOpen) {
      const openFence = fenceOpen[1];
      const openChar = openFence[0];
      const openLen = openFence.length;
      const rawLang = fenceOpen[2] ?? "";
      const safeLang = /^[a-zA-Z0-9_+-]+$/.test(rawLang) ? rawLang : "";
      const codeLines: string[] = [];
      i += 1;
      while (i < lines.length) {
        const closeMatch = /^\s*(`{3,}|~{3,})\s*$/.exec(lines[i]);
        if (closeMatch && closeMatch[1][0] === openChar && closeMatch[1].length >= openLen) {
          i += 1;
          break;
        }
        codeLines.push(lines[i]);
        i += 1;
      }
      const langLabel = safeLang ? `<div class="md-code-lang">${escapeHtml(safeLang)}</div>` : "";
      const langClass = safeLang ? ` class="language-${escapeHtml(safeLang)}"` : "";
      html.push(
        `<div class="md-code-block">${langLabel}<pre><code${langClass}>${escapeHtml(codeLines.join("\n"))}</code></pre></div>`,
      );
      continue;
    }

    // 2. ATX headings (H1–H6)
    const heading = HEADING_RE.exec(line);
    if (heading) {
      const level = heading[1].length;
      html.push(`<h${level}>${formatInline(heading[2])}</h${level}>`);
      i += 1;
      continue;
    }

    // 3. Horizontal rules
    if (HR_RE.test(line)) {
      html.push("<hr />");
      i += 1;
      continue;
    }

    // 4. GFM Alerts & Blockquotes
    const bqStart = BLOCKQUOTE_RE.exec(line);
    if (bqStart) {
      const innerLines: string[] = [];
      while (i < lines.length) {
        const bqLine = BLOCKQUOTE_RE.exec(lines[i]);
        if (!bqLine) break;
        innerLines.push(bqLine[1]);
        i += 1;
      }
      const alertMatch = innerLines.length > 0 ? ALERT_MARKER_RE.exec(innerLines[0]) : null;
      if (alertMatch) {
        const alertType = alertMatch[1].toLowerCase() as AlertType;
        const customTitle = alertMatch[2]?.trim() ?? "";
        const titleHtml = customTitle ? formatInline(customTitle) : ALERT_DEFAULTS[alertType];
        const bodyLines = innerLines.slice(1);
        const bodyHtml = bodyLines.some((l) => l.trim() !== "") ? renderBlocks(bodyLines) : "";
        const bodySection = bodyHtml ? `<div class="md-alert-body">${bodyHtml}</div>` : "";
        html.push(
          `<div class="md-alert md-alert-${alertType}" role="note"><div class="md-alert-title">${alertIconSvg(alertType)}<span>${titleHtml}</span></div>${bodySection}</div>`,
        );
      } else {
        html.push(`<blockquote>${renderBlocks(innerLines)}</blockquote>`);
      }
      continue;
    }

    // 5. GFM Pipe Tables
    const tableMatch = tryMatchTableAt(lines, i);
    if (tableMatch) {
      const { headers, alignments } = tableMatch;
      const colCount = headers.length;
      i += 2;
      const rows: string[][] = [];
      while (i < lines.length) {
        const rowLine = lines[i];
        if (!rowLine.trim() || !rowLine.includes("|")) break;
        if (
          FENCE_OPEN_RE.test(rowLine) ||
          HEADING_RE.test(rowLine) ||
          HR_RE.test(rowLine) ||
          BLOCKQUOTE_RE.test(rowLine)
        ) {
          break;
        }
        const rawCells = splitTableRow(rowLine);
        const padded: string[] = [];
        for (let c = 0; c < colCount; c += 1) {
          padded.push(rawCells[c] ?? "");
        }
        rows.push(padded);
        i += 1;
      }

      const alignAttr = (idx: number) => {
        const align = alignments[idx];
        return align ? ` style="text-align:${align}"` : "";
      };

      const theadHtml = `<thead><tr>${headers.map((h, idx) => `<th${alignAttr(idx)}>${formatInline(h)}</th>`).join("")}</tr></thead>`;
      const tbodyHtml =
        rows.length > 0
          ? `<tbody>${rows.map((row) => `<tr>${row.map((cell, idx) => `<td${alignAttr(idx)}>${formatInline(cell)}</td>`).join("")}</tr>`).join("")}</tbody>`
          : "<tbody></tbody>";
      html.push(`<div class="md-table-wrap"><table>${theadHtml}${tbodyHtml}</table></div>`);
      continue;
    }

    // 6. Lists (ordered, unordered, nested, task lists)
    const listStart = matchListItem(line);
    if (listStart) {
      const parsed = parseList(lines, i, listStart.indent, listStart.ordered);
      html.push(parsed.html);
      i = parsed.nextIndex;
      continue;
    }

    // 7. Paragraphs
    const paraLines: string[] = [line.trim()];
    i += 1;
    while (i < lines.length && !isBlockStarter(lines, i)) {
      paraLines.push(lines[i].trim());
      i += 1;
    }
    html.push(`<p>${paraLines.map((pLine) => formatInline(pLine)).join("<br />")}</p>`);
  }

  return html.join("\n");
}

export function renderMarkdown(md: string): string {
  const safeMd = md.replace(/\u0000/g, "");
  if (!safeMd.trim()) {
    return `<div class="empty-state">暂无内容</div>`;
  }
  const lines = safeMd.split(/\r?\n/);
  return renderBlocks(lines);
}
