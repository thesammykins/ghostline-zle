const GUARDED_ALIASED_COMMANDS = new Set([
  "find",
  "grep",
  "cat",
  "ls",
  "du",
  "diff",
  "top",
  "ps",
]);

export const sanitizeCommand = (value) => {
  if (typeof value !== "string") return "";
  let trimmed = value.trim();
  if (trimmed.length === 0) return "";
  if (/[\r\n]/.test(trimmed)) return "";
  if (trimmed.includes("```")) return "";
  trimmed = trimmed.replace(/^command:\s*/i, "");
  if (trimmed.length === 0) return "";
  if (/[\u0000-\u001F\u007F]/.test(trimmed)) return "";
  return trimmed;
};

export const detectIntentMode = (prompt) => {
  const text = (prompt || "").toLowerCase();
  if (/\b(git|commit|branch|rebase|stash|cherry-pick|merge)\b/.test(text)) {
    return "git";
  }
  if (/\b(port|dns|ip|network|curl|wget|ping|http|https|route|socket)\b/.test(text)) {
    return "network";
  }
  if (/\b(delete|remove|rm\b|rename|move|install|update|set|change|kill|chmod|chown|write)\b/.test(text)) {
    return "modify";
  }
  return "inspect";
};

export const parseAliasContext = (raw) => {
  const result = {};
  if (typeof raw !== "string" || raw.trim().length === 0) {
    return result;
  }
  const entries = raw.includes("\n")
    ? raw.split(/\r?\n/)
    : raw.split(";");
  for (const entry of entries) {
    const token = entry.trim();
    if (!token) continue;
    const normalized = token.startsWith("alias ") ? token.slice(6).trim() : token;
    const eqIndex = normalized.indexOf("=");
    if (eqIndex <= 0) continue;
    const key = normalized.slice(0, eqIndex).trim();
    let value = normalized.slice(eqIndex + 1).trim();
    if ((value.startsWith("'") && value.endsWith("'")) || (value.startsWith('"') && value.endsWith('"'))) {
      value = value.slice(1, -1);
    }
    if (!/^[A-Za-z0-9_-]+$/.test(key) || !value) continue;
    result[key] = value;
  }
  return result;
};

const firstToken = (command) => {
  if (typeof command !== "string") return "";
  const parts = command.trim().split(/\s+/).filter(Boolean);
  return parts[0] || "";
};

export const applyAliasGuard = (command, aliasContext) => {
  const token = firstToken(command);
  if (!token || token === "command") {
    return command;
  }
  if (!GUARDED_ALIASED_COMMANDS.has(token)) {
    return command;
  }
  if (!aliasContext[token]) {
    return command;
  }
  return `command ${command}`;
};

const hasDestructivePattern = (command) =>
  /\brm\s+-rf\b|\bmkfs\b|\bdd\s+if=|\bshutdown\b|\breboot\b|\bpoweroff\b/.test(command);

const scoreCandidate = (candidate, { intentMode, userPrompt }) => {
  let score = 0;
  if (candidate && !/[\r\n]/.test(candidate)) score += 5;
  if (!candidate.includes(";;") && !candidate.includes("&&&")) score += 2;
  if (candidate.startsWith("command ")) score += 1;
  if (intentMode === "inspect" && hasDestructivePattern(candidate)) score -= 15;
  if (/\bsudo\b/.test(candidate) && !/\bsudo\b/i.test(userPrompt || "")) score -= 3;
  if (/\b\|\s*xargs\s+rm\b/.test(candidate)) score -= 4;
  return score;
};

export const rankCommandCandidates = ({
  rawCommand,
  aliasContext,
  intentMode,
  userPrompt,
}) => {
  const base = sanitizeCommand(rawCommand);
  if (!base) {
    return { command: "", candidates: [] };
  }

  const guarded = applyAliasGuard(base, aliasContext);
  const unique = [];
  const seen = new Set();
  for (const candidate of [base, guarded]) {
    const normalized = sanitizeCommand(candidate);
    if (!normalized || seen.has(normalized)) continue;
    seen.add(normalized);
    unique.push(normalized);
  }

  if (unique.length === 0) {
    return { command: "", candidates: [] };
  }

  const ranked = unique
    .map((candidate) => ({
      candidate,
      score: scoreCandidate(candidate, { intentMode, userPrompt }),
    }))
    .sort((a, b) => b.score - a.score);

  return {
    command: ranked[0].candidate,
    candidates: ranked.map((item) => item.candidate),
  };
};
