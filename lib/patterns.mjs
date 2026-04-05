import fs from "node:fs";
import path from "node:path";
import { getConfigPath, loadConfig } from "./config.mjs";

const shellEscapeSingleQuotes = (value) => String(value).replace(/'/g, `'"'"'`);

const normalizePathToken = (value, { cwd = "", home = "" } = {}) => {
  if (typeof value !== "string") return cwd || ".";
  const trimmed = value.trim();
  if (!trimmed || /^(here|this directory)$/i.test(trimmed)) return cwd || ".";
  if (trimmed === "~") return home || "~";
  if (trimmed.startsWith("~/")) {
    return home ? `${home}${trimmed.slice(1)}` : trimmed;
  }
  return trimmed;
};

const expandTemplate = (template, captures, context) => {
  const lookup = {
    cwd: context.cwd || ".",
    home: context.home || "",
    dotfiles: context.dotfiles || "",
    target: captures.target || "",
    target_quoted: shellEscapeSingleQuotes(captures.target || ""),
  };

  return String(template).replace(/\{([a-z_]+)\}/gi, (_match, key) => lookup[key] ?? "");
};

const buildCaptures = (match, pattern, context) => {
  const groups = match.groups || {};
  const targetRaw = groups.target || groups.path || "";
  return {
    target: normalizePathToken(targetRaw, context),
  };
};

export const getDefaultPatterns = () => [
  {
    name: "list-files-in-path",
    mode: "generate",
    regex: "^(?:show|list|find)(?: me)?(?: all)? files(?: in)? (?<target>.+)$",
    flags: "i",
    command: 'command find "{target}" -type f -print | sed "s:^$HOME:~:" | sort',
  },
  {
    name: "list-files-here",
    mode: "generate",
    regex: "^(?:show|list)(?: me)?(?: all)? files(?: here| in this directory)?$",
    flags: "i",
    command: 'command find . -type f -print | sed "s:^\\./::" | sort',
  },
];

export const getPatternFilePath = () => {
  const configPath = getConfigPath();
  return path.join(path.dirname(configPath), "patterns.json");
};

export const loadPatterns = () => {
  const config = loadConfig();
  const defaults = getDefaultPatterns();
  if (config.patterns?.enabled === false) return [];

  if (config.patterns?.source === "config") {
    return Array.isArray(config.patterns.entries) ? config.patterns.entries : defaults;
  }

  const patternPath = getPatternFilePath();
  try {
    if (!fs.existsSync(patternPath)) return defaults;
    const raw = fs.readFileSync(patternPath, "utf8").trim();
    if (!raw) return defaults;
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : defaults;
  } catch {
    return defaults;
  }
};

export const resolvePatternCommand = ({ prompt = "", mode = "generate", cwd = "", home = "", dotfiles = "" } = {}) => {
  if (!prompt || mode !== "generate") return "";

  const context = { cwd, home, dotfiles };
  for (const pattern of loadPatterns()) {
    if (!pattern || typeof pattern !== "object") continue;
    if (pattern.mode && pattern.mode !== mode) continue;
    if (typeof pattern.regex !== "string" || typeof pattern.command !== "string") continue;
    try {
      const expression = new RegExp(pattern.regex, typeof pattern.flags === "string" ? pattern.flags : "i");
      const match = prompt.trim().match(expression);
      if (!match) continue;
      const captures = buildCaptures(match, pattern, context);
      return expandTemplate(pattern.command, captures, context).trim();
    } catch {
      continue;
    }
  }

  return "";
};
