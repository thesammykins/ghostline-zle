import fs from "node:fs";
import path from "node:path";
import os from "node:os";

const DATA_DIR =
  process.env.COPILOT_ZLE_DATA_DIR ||
  path.join(os.homedir(), ".local", "share", "copilot-zle");
const LOG_FILE = path.join(DATA_DIR, "flight-log.jsonl");

const DEFAULT_MAX_ENTRIES = 1000;
const DEFAULT_FEW_SHOT_COUNT = 3;

const ensureDir = (dir) => {
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
};

const safeReadLines = (filePath, maxLines = DEFAULT_MAX_ENTRIES) => {
  if (!fs.existsSync(filePath)) return [];
  try {
    const content = fs.readFileSync(filePath, "utf8").trim();
    if (!content) return [];
    const lines = content.split("\n").filter(Boolean);
    return lines.slice(-maxLines);
  } catch {
    return [];
  }
};

const parseEntry = (line) => {
  try {
    return JSON.parse(line);
  } catch {
    return null;
  }
};

export const recordGeneration = ({
  prompt,
  command,
  mode = "generate",
  cwd = "",
  durationMs = 0,
  maxEntries = DEFAULT_MAX_ENTRIES,
}) => {
  if (!prompt || !command) return;
  ensureDir(DATA_DIR);

  const entry = {
    ts: Math.floor(Date.now() / 1000),
    prompt,
    command,
    executed: false,
    exit_code: null,
    mode,
    cwd,
    duration_ms: durationMs,
  };

  try {
    fs.appendFileSync(LOG_FILE, JSON.stringify(entry) + "\n", "utf8");
  } catch {
    return;
  }

  // Rotate if over limit
  try {
    const lines = safeReadLines(LOG_FILE, maxEntries + 100);
    if (lines.length > maxEntries) {
      const trimmed = lines.slice(-maxEntries);
      fs.writeFileSync(LOG_FILE, trimmed.join("\n") + "\n", "utf8");
    }
  } catch {
    // Best effort rotation
  }
};

export const markExecuted = (command, exitCode) => {
  if (!command || !fs.existsSync(LOG_FILE)) return;

  try {
    const lines = safeReadLines(LOG_FILE);
    let found = false;

    // Walk backwards to find the most recent matching entry
    for (let i = lines.length - 1; i >= 0; i--) {
      const entry = parseEntry(lines[i]);
      if (entry && entry.command === command && !entry.executed) {
        entry.executed = true;
        entry.exit_code = typeof exitCode === "number" ? exitCode : null;
        lines[i] = JSON.stringify(entry);
        found = true;
        break;
      }
    }

    if (found) {
      fs.writeFileSync(LOG_FILE, lines.join("\n") + "\n", "utf8");
    }
  } catch {
    // Best effort
  }
};

const tokenize = (text) =>
  (text || "")
    .toLowerCase()
    .split(/\s+/)
    .filter((w) => w.length > 1);

const overlapScore = (tokensA, tokensB) => {
  const setB = new Set(tokensB);
  let hits = 0;
  for (const t of tokensA) {
    if (setB.has(t)) hits++;
  }
  return hits;
};

export const queryRelevant = ({
  prompt = "",
  cwd = "",
  mode = "generate",
  limit = DEFAULT_FEW_SHOT_COUNT,
}) => {
  if (!fs.existsSync(LOG_FILE)) return [];

  const lines = safeReadLines(LOG_FILE);
  const promptTokens = tokenize(prompt);

  const scored = [];
  for (const line of lines) {
    const entry = parseEntry(line);
    if (!entry || !entry.executed || entry.exit_code !== 0) continue;

    let score = 0;
    // Keyword overlap with prompt
    score += overlapScore(promptTokens, tokenize(entry.prompt)) * 3;
    // Same CWD prefix
    if (cwd && entry.cwd && cwd.startsWith(entry.cwd)) score += 2;
    if (cwd && entry.cwd && entry.cwd === cwd) score += 3;
    // Same mode
    if (entry.mode === mode) score += 1;
    // Recency bonus (newer entries have higher ts)
    score += 0.001 * (entry.ts || 0);

    if (score > 0) {
      scored.push({ entry, score });
    }
  }

  scored.sort((a, b) => b.score - a.score);
  return scored.slice(0, limit).map((s) => s.entry);
};

export const queryFollowUps = ({ command = "", limit = 3 }) => {
  if (!command || !fs.existsSync(LOG_FILE)) return [];

  const lines = safeReadLines(LOG_FILE);
  const entries = lines.map(parseEntry).filter(Boolean);

  // Build a frequency map: after executing `command`, what did the user generate next?
  const followCounts = {};
  for (let i = 0; i < entries.length - 1; i++) {
    const current = entries[i];
    const next = entries[i + 1];
    if (
      current.command === command &&
      current.executed &&
      current.exit_code === 0 &&
      next.command &&
      next.command !== command
    ) {
      followCounts[next.command] = (followCounts[next.command] || 0) + 1;
    }
  }

  return Object.entries(followCounts)
    .sort((a, b) => b[1] - a[1])
    .slice(0, limit)
    .map(([cmd, count]) => ({ command: cmd, count }));
};

export const getTopFollowUp = ({ command = "", cwd = "" } = {}) => {
  if (!command || !fs.existsSync(LOG_FILE)) return null;

  const lines = safeReadLines(LOG_FILE);
  const entries = lines.map(parseEntry).filter(Boolean);
  let best = null;

  for (let i = 0; i < entries.length - 1; i++) {
    const current = entries[i];
    const next = entries[i + 1];
    if (
      current.command !== command ||
      !current.executed ||
      current.exit_code !== 0 ||
      !next.command ||
      next.command === command
    ) {
      continue;
    }

    let score = 1;
    if (cwd && next.cwd === cwd) score += 3;
    else if (cwd && next.cwd && cwd.startsWith(next.cwd)) score += 1;
    score += 0.001 * (next.ts || 0);

    if (!best || score > best.score) {
      best = { command: next.command, score };
    }
  }

  return best ? best.command : null;
};

export const buildFewShotBlock = (entries) => {
  if (!entries || entries.length === 0) return "";
  const examples = entries
    .map((e) => `User: ${e.prompt}\nCommand: ${e.command}`)
    .join("\n\n");
  return `\nPATTERN MEMORY (commands you've used before):\n${examples}`;
};

export const getLogPath = () => LOG_FILE;
