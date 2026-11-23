import { safeOpenat } from "./native.js";

export const UINT64_MAX = 18446744073709551615n;

export interface TopLevelJsonEntry {
  key: string;
  keyStart: number;
  keyEnd: number;
  valStart: number;
  valEnd: number;
}

export interface ScannedTopLevelObject {
  entries: TopLevelJsonEntry[];
  closingBraceIndex: number;
}

function skipWs(text: string, pos: number): number {
  const len = text.length;
  let i = pos;
  while (i < len) {
    const ch = text.charCodeAt(i);
    if (ch === 0x20 || ch === 0x09 || ch === 0x0a || ch === 0x0d) {
      i += 1;
    } else {
      break;
    }
  }
  return i;
}

function skipString(text: string, pos: number): number {
  const len = text.length;
  if (pos >= len || text.charCodeAt(pos) !== 0x22) {
    throw new SyntaxError(`Expected JSON string at offset ${pos}`);
  }
  let i = pos + 1;
  while (i < len) {
    const ch = text.charCodeAt(i);
    if (ch === 0x5c) {
      if (i + 1 >= len) {
        throw new SyntaxError("Unterminated escape in JSON string");
      }
      i += 2;
    } else if (ch === 0x22) {
      return i + 1;
    } else {
      i += 1;
    }
  }
  throw new SyntaxError("Unterminated JSON string");
}

function skipValue(text: string, pos: number): number {
  const len = text.length;
  if (pos >= len) {
    throw new SyntaxError("Unexpected end of JSON value");
  }
  const ch = text.charCodeAt(pos);
  if (ch === 0x22) {
    return skipString(text, pos);
  }
  if (ch === 0x7b || ch === 0x5b) {
    let depth = 1;
    let i = pos + 1;
    while (i < len && depth > 0) {
      const c = text.charCodeAt(i);
      if (c === 0x22) {
        i = skipString(text, i);
      } else if (c === 0x7b || c === 0x5b) {
        depth += 1;
        i += 1;
      } else if (c === 0x7d || c === 0x5d) {
        depth -= 1;
        i += 1;
      } else {
        i += 1;
      }
    }
    if (depth !== 0) {
      throw new SyntaxError("Unterminated JSON container");
    }
    return i;
  }

  let i = pos;
  while (i < len) {
    const c = text.charCodeAt(i);
    if (
      c === 0x2c ||
      c === 0x7d ||
      c === 0x5d ||
      c === 0x20 ||
      c === 0x09 ||
      c === 0x0a ||
      c === 0x0d
    ) {
      break;
    }
    i += 1;
  }
  if (i === pos) {
    throw new SyntaxError(`Unexpected token in JSON at offset ${pos}`);
  }
  return i;
}

export function scanTopLevelJsonObject(jsonText: string): ScannedTopLevelObject {
  const len = jsonText.length;
  let i = skipWs(jsonText, 0);
  if (i >= len || jsonText.charCodeAt(i) !== 0x7b) {
    throw new SyntaxError("Top-level JSON must be an object");
  }
  i += 1;

  const entries: TopLevelJsonEntry[] = [];
  i = skipWs(jsonText, i);
  if (i < len && jsonText.charCodeAt(i) === 0x7d) {
    const closingBraceIndex = i;
    const endCheck = skipWs(jsonText, i + 1);
    if (endCheck !== len) {
      throw new SyntaxError("Unexpected trailing tokens after JSON object");
    }
    return { entries, closingBraceIndex };
  }

  while (true) {
    i = skipWs(jsonText, i);
    if (i >= len || jsonText.charCodeAt(i) !== 0x22) {
      throw new SyntaxError(`Expected JSON property name at offset ${i}`);
    }
    const keyStart = i;
    const keyEnd = skipString(jsonText, keyStart);
    const decodedKey = JSON.parse(jsonText.slice(keyStart, keyEnd)) as string;
    i = skipWs(jsonText, keyEnd);
    if (i >= len || jsonText.charCodeAt(i) !== 0x3a) {
      throw new SyntaxError(`Expected ':' after key at offset ${i}`);
    }
    const valStart = skipWs(jsonText, i + 1);
    const valEnd = skipValue(jsonText, valStart);
    entries.push({
      key: decodedKey,
      keyStart,
      keyEnd,
      valStart,
      valEnd,
    });

    i = skipWs(jsonText, valEnd);
    if (i < len && jsonText.charCodeAt(i) === 0x2c) {
      i += 1;
      continue;
    }
    if (i < len && jsonText.charCodeAt(i) === 0x7d) {
      const closingBraceIndex = i;
      const endCheck = skipWs(jsonText, i + 1);
      if (endCheck !== len) {
        throw new SyntaxError("Unexpected trailing tokens after JSON object");
      }
      return { entries, closingBraceIndex };
    }
    throw new SyntaxError(`Expected ',' or '}' at offset ${i}`);
  }
}

export function parseRawNonNegativeUint64(rawToken: string): bigint | null {
  if (rawToken === "-0") {
    return 0n;
  }
  if (/^(?:0|[1-9][0-9]*)$/.test(rawToken)) {
    const val = BigInt(rawToken);
    return val <= UINT64_MAX ? val : null;
  }
  const m = /^(-)?(0|[1-9][0-9]*)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$/.exec(rawToken);
  if (!m) {
    return null;
  }
  const decoded = safeOpenat.decode_swift_uint64(rawToken);
  return decoded !== null ? BigInt(decoded) : null;
}

export function extractTopLevelRawTokens(jsonText: string): Map<string, string> {
  const parsed: unknown = JSON.parse(jsonText);
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new SyntaxError("Top-level JSON must be an object");
  }
  const { entries } = scanTopLevelJsonObject(jsonText);
  const tokens = new Map<string, string>();
  for (const entry of entries) {
    tokens.set(entry.key, jsonText.slice(entry.valStart, entry.valEnd));
  }
  return tokens;
}

export function canonicalizeRawJsonToken(raw: string): string {
  const trimmed = raw.trim();
  if (!trimmed) {
    throw new SyntaxError("Empty JSON value token");
  }
  const ch = trimmed.charCodeAt(0);
  if (ch === 0x22) {
    return JSON.stringify(JSON.parse(trimmed));
  }
  if (ch === 0x7b) {
    const { entries } = scanTopLevelJsonObject(trimmed);
    const deduped = new Map<string, string>();
    for (const entry of entries) {
      deduped.set(entry.key, canonicalizeRawJsonToken(trimmed.slice(entry.valStart, entry.valEnd)));
    }
    const sorted = [...deduped.entries()].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
    return `{${sorted.map(([k, v]) => `${JSON.stringify(k)}:${v}`).join(",")}}`;
  }
  if (ch === 0x5b) {
    const len = trimmed.length;
    let i = skipWs(trimmed, 1);
    const elems: string[] = [];
    if (i < len && trimmed.charCodeAt(i) === 0x5d) {
      const endCheck = skipWs(trimmed, i + 1);
      if (endCheck !== len) {
        throw new SyntaxError("Unexpected trailing tokens after JSON array");
      }
      return "[]";
    }
    while (true) {
      const valStart = skipWs(trimmed, i);
      const valEnd = skipValue(trimmed, valStart);
      elems.push(canonicalizeRawJsonToken(trimmed.slice(valStart, valEnd)));
      i = skipWs(trimmed, valEnd);
      if (i < len && trimmed.charCodeAt(i) === 0x2c) {
        i += 1;
        continue;
      }
      if (i < len && trimmed.charCodeAt(i) === 0x5d) {
        const endCheck = skipWs(trimmed, i + 1);
        if (endCheck !== len) {
          throw new SyntaxError("Unexpected trailing tokens after JSON array");
        }
        return `[${elems.join(",")}]`;
      }
      throw new SyntaxError(`Expected ',' or ']' at offset ${i}`);
    }
  }
  if (trimmed === "true" || trimmed === "false" || trimmed === "null") {
    return trimmed;
  }
  const parsed: unknown = JSON.parse(trimmed);
  if (typeof parsed !== "number") {
    throw new SyntaxError(`Unexpected JSON token: ${trimmed}`);
  }
  return trimmed === "-0" ? "0" : trimmed;
}

export function rawJsonTokensEqual(a: string | undefined, b: string | undefined): boolean {
  if (a === undefined || b === undefined) return a === b;
  if (a === b) return true;
  return canonicalizeRawJsonToken(a) === canonicalizeRawJsonToken(b);
}

export function patchTopLevelJsonRawFields(
  jsonText: string,
  rawPatches: Map<string, string> | Record<string, string>,
  options?: { compactMissing?: boolean; removeKeys?: string[] },
): string {
  const normalizedPatches = new Map<string, string>();
  const patchEntries =
    rawPatches instanceof Map ? [...rawPatches.entries()] : Object.entries(rawPatches);
  for (const [k, raw] of patchEntries) {
    if (typeof raw !== "string" || !raw.trim()) {
      throw new SyntaxError(`Invalid raw JSON patch token for key ${k}`);
    }
    JSON.parse(raw);
    normalizedPatches.set(k, raw.trim());
  }

  let out = jsonText;
  if (options?.removeKeys) {
    for (const k of options.removeKeys) {
      if (!normalizedPatches.has(k)) {
        out = removeTopLevelJsonField(out, k);
      }
    }
  }

  const { entries, closingBraceIndex } = scanTopLevelJsonObject(out);
  const edits: Array<{ start: number; end: number; replacement: string }> = [];
  const matchedKeys = new Set<string>();

  for (const entry of entries) {
    if (normalizedPatches.has(entry.key)) {
      matchedKeys.add(entry.key);
      edits.push({
        start: entry.valStart,
        end: entry.valEnd,
        replacement: normalizedPatches.get(entry.key)!,
      });
    }
  }

  const missingKeys = [...normalizedPatches.keys()].filter((k) => !matchedKeys.has(k));
  if (missingKeys.length > 0) {
    let isPretty = false;
    if (!options?.compactMissing) {
      if (entries.length >= 2) {
        isPretty = out
          .slice(entries[entries.length - 2].valEnd, entries[entries.length - 1].keyStart)
          .includes("\n");
      } else if (entries.length === 1) {
        isPretty =
          out.slice(0, entries[0].keyStart).includes("\n") &&
          out.slice(entries[0].valEnd, closingBraceIndex).includes("\n");
      }
    }
    const indentMatch =
      entries.length > 0 ? /\n([ \t]+)$/.exec(out.slice(0, entries[0].keyStart)) : null;
    const indent = indentMatch ? indentMatch[1] : "  ";
    const lastEnd = entries.length > 0 ? entries[entries.length - 1].valEnd : closingBraceIndex;
    const serializedMissing = missingKeys.map((k) =>
      isPretty
        ? `${indent}${JSON.stringify(k)}: ${normalizedPatches.get(k)!}`
        : `${JSON.stringify(k)}:${normalizedPatches.get(k)!}`,
    );

    if (entries.length === 0) {
      const insertText = isPretty
        ? `\n${serializedMissing.join(",\n")}\n`
        : serializedMissing.join(",");
      edits.push({ start: closingBraceIndex, end: closingBraceIndex, replacement: insertText });
    } else if (isPretty) {
      const trailingGap = out.slice(lastEnd, closingBraceIndex);
      const newlineSuffix = trailingGap.startsWith("\r\n") ? "\r\n" : "\n";
      edits.push({
        start: lastEnd,
        end: closingBraceIndex,
        replacement: `,${newlineSuffix}${serializedMissing.join(`,${newlineSuffix}`)}${trailingGap}`,
      });
    } else {
      edits.push({
        start: lastEnd,
        end: lastEnd,
        replacement: `,${serializedMissing.join(",")}`,
      });
    }
  }

  edits.sort((a, b) => b.start - a.start);
  for (const edit of edits) {
    out = out.slice(0, edit.start) + edit.replacement + out.slice(edit.end);
  }
  JSON.parse(out);
  return out;
}

export function patchTopLevelJsonFields(
  jsonText: string,
  patches: Record<string, unknown>,
  options?: { compactMissing?: boolean },
): string {
  const rawPatches = new Map<string, string>();
  for (const [k, v] of Object.entries(patches)) {
    const serialized = JSON.stringify(v);
    if (serialized === undefined) {
      throw new TypeError(`Cannot serialize undefined JSON patch value for key ${k}`);
    }
    rawPatches.set(k, serialized);
  }
  return patchTopLevelJsonRawFields(jsonText, rawPatches, options);
}

export function removeTopLevelJsonField(jsonText: string, keyToRemove: string): string {
  let out = jsonText;
  while (true) {
    const { entries, closingBraceIndex } = scanTopLevelJsonObject(out);
    let idx = -1;
    for (let i = entries.length - 1; i >= 0; i -= 1) {
      if (entries[i].key === keyToRemove) {
        idx = i;
        break;
      }
    }
    if (idx === -1) {
      break;
    }
    if (entries.length === 1) {
      const openBrace = skipWs(out, 0);
      out = out.slice(0, openBrace + 1) + out.slice(closingBraceIndex);
    } else if (idx < entries.length - 1) {
      out = out.slice(0, entries[idx].keyStart) + out.slice(entries[idx + 1].keyStart);
    } else {
      out = out.slice(0, entries[idx - 1].valEnd) + out.slice(entries[idx].valEnd);
    }
  }
  JSON.parse(out);
  return out;
}
