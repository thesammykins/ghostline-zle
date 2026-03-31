import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const helperDir = path.dirname(fileURLToPath(import.meta.url));
const repoDir = path.dirname(helperDir);

const DEFAULT_CONFIG = {
  model: {
    default: "gpt-5-mini",
  },
  tools: {
    allowlist: [],
    devopsEnabled: false,
  },
  limits: {
    maxOutputBytes: 200000,
    maxFileBytes: 1000000,
    toolTimeoutMs: 4000,
  },
  context: {
    recentHistoryCount: 5,
    includeGitSummary: true,
    includeLastFailure: true,
    includeProjectInfo: true,
  },
  ui: {
    highlightAiBuffer: true,
    highlightStyle: "underline",
  },
  daemon: {
    enabled: true,
    idleTimeoutSec: 300,
  },
  suggest: {
    enabled: false,
    debounceMs: 500,
    rateLimitMs: 2000,
    skipCommands: ["cd", "ls", "clear", "pwd", "exit", "true", "false"],
    ghostStyle: "fg=240",
  },
  nlDetection: {
    enabled: false,
    minWords: 3,
    indicator: "[NL]",
  },
  autofix: {
    enabled: false,
    displayMode: "banner",
  },
  flightLog: {
    enabled: true,
    maxEntries: 1000,
    fewShotCount: 3,
  },
  branding: {
    productName: "ghostline-zle",
    statusPrefix: "[GHOSTLINE]",
    errorPrefix: "[GHOSTLINE ERROR]",
    fixPrefix: "[GHOSTLINE FIX]",
    explainPrefix: "[GHOSTLINE HELP]",
    thinkingLabel: "WHISPERING",
  },
};

const normalizeAllowlist = (value) => {
  if (Array.isArray(value)) {
    return value
      .map((item) => (typeof item === "string" ? item.trim().toLowerCase() : ""))
      .filter((item) => item.length > 0);
  }
  if (typeof value !== "string") return [];
  return value
    .split(/[\s,]+/)
    .map((token) => token.trim().toLowerCase())
    .filter((token) => token.length > 0);
};

const readJsonFile = (filePath) => {
  if (!fs.existsSync(filePath)) return null;
  const raw = fs.readFileSync(filePath, "utf8");
  if (!raw.trim()) return null;
  return JSON.parse(raw);
};

const pickNumber = (value, fallback) =>
  Number.isFinite(value) ? Number(value) : fallback;

const pickBoolean = (value, fallback) =>
  typeof value === "boolean" ? value : fallback;

const pickString = (value, fallback) =>
  typeof value === "string" && value.trim().length > 0 ? value.trim() : fallback;

const clampNumber = (value, fallback, minimum) => {
  const selected = Number.isFinite(value) ? Number(value) : fallback;
  return selected < minimum ? fallback : selected;
};

const buildConfig = (input) => {
  const safe = input && typeof input === "object" ? input : {};
  const modelInput = safe.model && typeof safe.model === "object" ? safe.model : {};
  const toolsInput = safe.tools && typeof safe.tools === "object" ? safe.tools : {};
  const limitsInput =
    safe.limits && typeof safe.limits === "object" ? safe.limits : {};

  const contextInput =
    safe.context && typeof safe.context === "object" ? safe.context : {};
  const uiInput =
    safe.ui && typeof safe.ui === "object" ? safe.ui : {};
  const daemonInput =
    safe.daemon && typeof safe.daemon === "object" ? safe.daemon : {};
  const suggestInput =
    safe.suggest && typeof safe.suggest === "object" ? safe.suggest : {};
  const nlInput =
    safe.nlDetection && typeof safe.nlDetection === "object" ? safe.nlDetection : {};
  const autofixInput =
    safe.autofix && typeof safe.autofix === "object" ? safe.autofix : {};
  const flightLogInput =
    safe.flightLog && typeof safe.flightLog === "object" ? safe.flightLog : {};
  const brandingInput =
    safe.branding && typeof safe.branding === "object" ? safe.branding : {};

  const validHighlightStyles = new Set(["underline", "bold", "standout", "none"]);

  return {
    model: {
      default: pickString(modelInput.default, DEFAULT_CONFIG.model.default),
    },
    tools: {
      allowlist: normalizeAllowlist(toolsInput.allowlist),
      devopsEnabled: pickBoolean(toolsInput.devopsEnabled, false),
    },
    limits: {
      maxOutputBytes: clampNumber(limitsInput.maxOutputBytes, DEFAULT_CONFIG.limits.maxOutputBytes, 1024),
      maxFileBytes: clampNumber(limitsInput.maxFileBytes, DEFAULT_CONFIG.limits.maxFileBytes, 1024),
      toolTimeoutMs: clampNumber(limitsInput.toolTimeoutMs, DEFAULT_CONFIG.limits.toolTimeoutMs, 250),
    },
    context: {
      recentHistoryCount: clampNumber(contextInput.recentHistoryCount, DEFAULT_CONFIG.context.recentHistoryCount, 0),
      includeGitSummary: pickBoolean(contextInput.includeGitSummary, DEFAULT_CONFIG.context.includeGitSummary),
      includeLastFailure: pickBoolean(contextInput.includeLastFailure, DEFAULT_CONFIG.context.includeLastFailure),
      includeProjectInfo: pickBoolean(contextInput.includeProjectInfo, DEFAULT_CONFIG.context.includeProjectInfo),
    },
    ui: {
      highlightAiBuffer: pickBoolean(uiInput.highlightAiBuffer, DEFAULT_CONFIG.ui.highlightAiBuffer),
      highlightStyle: validHighlightStyles.has(uiInput.highlightStyle)
        ? uiInput.highlightStyle
        : DEFAULT_CONFIG.ui.highlightStyle,
    },
    daemon: {
      enabled: pickBoolean(daemonInput.enabled, DEFAULT_CONFIG.daemon.enabled),
      idleTimeoutSec: clampNumber(daemonInput.idleTimeoutSec, DEFAULT_CONFIG.daemon.idleTimeoutSec, 30),
    },
    suggest: {
      enabled: pickBoolean(suggestInput.enabled, DEFAULT_CONFIG.suggest.enabled),
      debounceMs: clampNumber(suggestInput.debounceMs, DEFAULT_CONFIG.suggest.debounceMs, 100),
      rateLimitMs: clampNumber(suggestInput.rateLimitMs, DEFAULT_CONFIG.suggest.rateLimitMs, 500),
      skipCommands: Array.isArray(suggestInput.skipCommands)
        ? suggestInput.skipCommands.filter((s) => typeof s === "string" && s.length > 0)
        : DEFAULT_CONFIG.suggest.skipCommands,
      ghostStyle: pickString(suggestInput.ghostStyle, DEFAULT_CONFIG.suggest.ghostStyle),
    },
    nlDetection: {
      enabled: pickBoolean(nlInput.enabled, DEFAULT_CONFIG.nlDetection.enabled),
      minWords: clampNumber(nlInput.minWords, DEFAULT_CONFIG.nlDetection.minWords, 2),
      indicator: pickString(nlInput.indicator, DEFAULT_CONFIG.nlDetection.indicator),
    },
    autofix: {
      enabled: pickBoolean(autofixInput.enabled, DEFAULT_CONFIG.autofix.enabled),
      displayMode: ["banner", "ghost"].includes(autofixInput.displayMode)
        ? autofixInput.displayMode
        : DEFAULT_CONFIG.autofix.displayMode,
    },
    flightLog: {
      enabled: pickBoolean(flightLogInput.enabled, DEFAULT_CONFIG.flightLog.enabled),
      maxEntries: clampNumber(flightLogInput.maxEntries, DEFAULT_CONFIG.flightLog.maxEntries, 100),
      fewShotCount: clampNumber(flightLogInput.fewShotCount, DEFAULT_CONFIG.flightLog.fewShotCount, 0),
    },
    branding: {
      productName: pickString(brandingInput.productName, DEFAULT_CONFIG.branding.productName),
      statusPrefix: pickString(brandingInput.statusPrefix, DEFAULT_CONFIG.branding.statusPrefix),
      errorPrefix: pickString(brandingInput.errorPrefix, DEFAULT_CONFIG.branding.errorPrefix),
      fixPrefix: pickString(brandingInput.fixPrefix, DEFAULT_CONFIG.branding.fixPrefix),
      explainPrefix: pickString(brandingInput.explainPrefix, DEFAULT_CONFIG.branding.explainPrefix),
      thinkingLabel: pickString(brandingInput.thinkingLabel, DEFAULT_CONFIG.branding.thinkingLabel),
    },
  };
};

export const loadConfig = () => {
  const configPath =
    process.env.COPILOT_ZLE_CONFIG_FILE || path.join(repoDir, "config.json");
  let fileConfig = null;
  try {
    fileConfig = readJsonFile(configPath);
  } catch {
    fileConfig = null;
  }

  const merged = buildConfig(fileConfig || {});

  const modelEnv = process.env.COPILOT_ZLE_MODEL;
  if (typeof modelEnv === "string" && modelEnv.trim().length > 0) {
    merged.model.default = modelEnv.trim();
  }

  const allowlistEnv = process.env.COPILOT_ZLE_TOOLS_ALLOWLIST;
  if (typeof allowlistEnv === "string" && allowlistEnv.trim().length > 0) {
    merged.tools.allowlist = normalizeAllowlist(allowlistEnv);
  }

  const devopsEnv = process.env.COPILOT_ZLE_TOOLS_DEVOPS;
  if (typeof devopsEnv === "string" && devopsEnv.trim().length > 0) {
    merged.tools.devopsEnabled = ["1", "true", "yes"].includes(
      devopsEnv.toLowerCase()
    );
  }

  const maxOutputEnv = Number.parseInt(
    process.env.COPILOT_ZLE_TOOL_MAX_OUTPUT_BYTES || "",
    10
  );
  if (Number.isFinite(maxOutputEnv)) {
    merged.limits.maxOutputBytes = clampNumber(
      maxOutputEnv,
      merged.limits.maxOutputBytes,
      1024
    );
  }

  const maxFileEnv = Number.parseInt(
    process.env.COPILOT_ZLE_TOOL_MAX_FILE_BYTES || "",
    10
  );
  if (Number.isFinite(maxFileEnv)) {
    merged.limits.maxFileBytes = clampNumber(
      maxFileEnv,
      merged.limits.maxFileBytes,
      1024
    );
  }

  const timeoutEnv = Number.parseInt(
    process.env.COPILOT_ZLE_TOOL_TIMEOUT_MS || "",
    10
  );
  if (Number.isFinite(timeoutEnv)) {
    merged.limits.toolTimeoutMs = clampNumber(
      timeoutEnv,
      merged.limits.toolTimeoutMs,
      250
    );
  }

  return merged;
};

export const getConfigPath = () =>
  process.env.COPILOT_ZLE_CONFIG_FILE || path.join(repoDir, "config.json");
