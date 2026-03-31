import assert from "node:assert/strict";
import { resolveModel, sanitizeCommand, parseInput, buildContextBlock } from "./copilot-helper.mjs";
import { loadConfig } from "./config.mjs";

const baseConfig = {
  model: { default: "gpt-5-mini" },
  tools: { allowlist: [], devopsEnabled: false },
  limits: { maxOutputBytes: 200000, maxFileBytes: 1000000, toolTimeoutMs: 4000 },
};

// ── resolveModel ────────────────────────────────────────────────────
assert.equal(resolveModel(baseConfig, {}), "gpt-5-mini");
assert.equal(
  resolveModel(baseConfig, { COPILOT_ZLE_MODEL: "gpt-5.4-mini" }),
  "gpt-5.4-mini"
);
assert.equal(
  resolveModel({ ...baseConfig, model: { default: "gpt-5.3-mini" } }, {}),
  "gpt-5.3-mini"
);

// ── sanitizeCommand ─────────────────────────────────────────────────
assert.equal(sanitizeCommand("ls -la"), "ls -la");
assert.equal(sanitizeCommand("command: rg TODO"), "rg TODO");
assert.equal(sanitizeCommand("first\nsecond"), "");

// Pipes, redirects, semicolons, and $() are now allowed for valid one-liners
assert.equal(sanitizeCommand("lsof -ti:8080 | xargs kill -9"), "lsof -ti:8080 | xargs kill -9");
assert.equal(sanitizeCommand("ls && pwd"), "ls && pwd");
assert.equal(sanitizeCommand("cat ~/.zshrc > out.txt"), "cat ~/.zshrc > out.txt");
assert.equal(sanitizeCommand("echo $(pwd)"), "echo $(pwd)");
assert.equal(sanitizeCommand("grep foo file.txt | wc -l"), "grep foo file.txt | wc -l");
assert.equal(sanitizeCommand("ls; echo done"), "ls; echo done");

// Dangerous patterns are still blocked
assert.equal(sanitizeCommand("eval 'rm -rf /'"), "");
assert.equal(sanitizeCommand("`malicious`"), "");
assert.equal(sanitizeCommand("```code block```"), "");
assert.equal(sanitizeCommand("first\nsecond"), "");

// ── parseInput (SAM-39) ─────────────────────────────────────────────
// Valid JSON payload
{
  const input = parseInput(JSON.stringify({
    prompt: "list files",
    mode: "generate",
    recentHistory: "ls\npwd",
    gitSummary: "main [dirty]",
    lastFailure: "",
    lastStderr: "",
    priorAi: { prompt: "", command: "" },
  }));
  assert.equal(input.prompt, "list files");
  assert.equal(input.mode, "generate");
  assert.equal(input.recentHistory, "ls\npwd");
  assert.equal(input.gitSummary, "main [dirty]");
  assert.equal(input.lastFailure, "");
  assert.equal(input.lastStderr, "");
  assert.equal(input.priorAi.prompt, "");
  assert.equal(input.priorAi.command, "");
}

// Fix mode payload
{
  const input = parseInput(JSON.stringify({
    prompt: "fix the last command that failed",
    mode: "fix",
    recentHistory: "git psh",
    gitSummary: "feature-branch",
    lastFailure: "git psh (exit 1)",
    lastStderr: "git: 'psh' is not a git command",
    priorAi: { prompt: "", command: "" },
  }));
  assert.equal(input.mode, "fix");
  assert.equal(input.lastFailure, "git psh (exit 1)");
  assert.equal(input.lastStderr, "git: 'psh' is not a git command");
}

// Refine mode payload
{
  const input = parseInput(JSON.stringify({
    prompt: "but use -la instead",
    mode: "refine",
    recentHistory: "",
    gitSummary: "",
    lastFailure: "",
    priorAi: { prompt: "list files", command: "ls" },
  }));
  assert.equal(input.mode, "refine");
  assert.equal(input.priorAi.prompt, "list files");
  assert.equal(input.priorAi.command, "ls");
}

// Raw text fallback (legacy)
{
  const input = parseInput("list all docker containers");
  assert.equal(input.prompt, "list all docker containers");
  assert.equal(input.mode, "generate");
  assert.equal(input.recentHistory, "");
}

// Malformed JSON falls back to raw text
{
  const input = parseInput("{broken json");
  assert.equal(input.prompt, "{broken json");
  assert.equal(input.mode, "generate");
}

// Empty / null / undefined
{
  const empty1 = parseInput("");
  assert.equal(empty1.prompt, "");
  const empty2 = parseInput(null);
  assert.equal(empty2.prompt, "");
  const empty3 = parseInput(undefined);
  assert.equal(empty3.prompt, "");
}

// ── buildContextBlock (SAM-39) ──────────────────────────────────────
// Generate mode with git info
{
  const ctx = buildContextBlock({
    mode: "generate",
    recentHistory: "ls\npwd",
    gitSummary: "main [dirty]",
    lastFailure: "",
    lastStderr: "",
    priorAi: { prompt: "", command: "" },
  });
  assert.ok(ctx.includes("GIT: main [dirty]"));
  assert.ok(ctx.includes("RECENT COMMANDS:"));
  assert.ok(!ctx.includes("MODE: FIX"));
  assert.ok(!ctx.includes("MODE: REFINE"));
}

// Fix mode
{
  const ctx = buildContextBlock({
    mode: "fix",
    recentHistory: "",
    gitSummary: "",
    lastFailure: "git psh (exit 1)",
    lastStderr: "",
    priorAi: { prompt: "", command: "" },
  });
  assert.ok(ctx.includes("FAILED COMMAND: git psh (exit 1)"));
  assert.ok(ctx.includes("MODE: FIX"));
}

// Fix mode with stderr
{
  const ctx = buildContextBlock({
    mode: "fix",
    recentHistory: "",
    gitSummary: "",
    lastFailure: "git psh (exit 1)",
    lastStderr: "git: 'psh' is not a git command",
    priorAi: { prompt: "", command: "" },
  });
  assert.ok(ctx.includes("STDERR OUTPUT:"));
  assert.ok(ctx.includes("git: 'psh' is not a git command"));
}

// Refine mode
{
  const ctx = buildContextBlock({
    mode: "refine",
    recentHistory: "",
    gitSummary: "",
    lastFailure: "",
    lastStderr: "",
    priorAi: { prompt: "list files", command: "ls" },
  });
  assert.ok(ctx.includes("PRIOR AI COMMAND: ls"));
  assert.ok(ctx.includes("PRIOR PROMPT: list files"));
  assert.ok(ctx.includes("MODE: REFINE"));
}

// Empty context returns empty string
{
  const ctx = buildContextBlock({
    mode: "generate",
    recentHistory: "",
    gitSummary: "",
    lastFailure: "",
    lastStderr: "",
    priorAi: { prompt: "", command: "" },
  });
  assert.equal(ctx, "");
}

// ── sanitizeCommand edge cases ──────────────────────────────────────
// Whitespace-only
assert.equal(sanitizeCommand("   "), "");
assert.equal(sanitizeCommand("\t"), "");
// Non-string types
assert.equal(sanitizeCommand(null), "");
assert.equal(sanitizeCommand(undefined), "");
assert.equal(sanitizeCommand(42), "");
assert.equal(sanitizeCommand({}), "");
// Control characters
assert.equal(sanitizeCommand("ls\x00"), "");
assert.equal(sanitizeCommand("ls\x07foo"), "");
// Very long valid input (should pass through)
{
  const longCmd = "find . " + Array(50).fill("-name '*.txt'").join(" ");
  assert.equal(sanitizeCommand(longCmd), longCmd);
}
// Command prefix stripping variants
assert.equal(sanitizeCommand("Command: ls -la"), "ls -la");
assert.equal(sanitizeCommand("COMMAND:  rg TODO"), "rg TODO");
// Triple backticks anywhere
assert.equal(sanitizeCommand("ls ```echo bad```"), "");
// Carriage return
assert.equal(sanitizeCommand("first\rsecond"), "");

// ── buildContextBlock edge cases ────────────────────────────────────
// All fields populated simultaneously
{
  const ctx = buildContextBlock({
    mode: "fix",
    recentHistory: "ls\npwd\ngit status",
    gitSummary: "feature-branch [dirty]",
    lastFailure: "npm test (exit 1)",
    lastStderr: "Error: test failed",
    priorAi: { prompt: "run tests", command: "npm test" },
  });
  assert.ok(ctx.includes("GIT: feature-branch [dirty]"));
  assert.ok(ctx.includes("RECENT COMMANDS:"));
  assert.ok(ctx.includes("FAILED COMMAND: npm test (exit 1)"));
  assert.ok(ctx.includes("STDERR OUTPUT:"));
  assert.ok(ctx.includes("MODE: FIX"));
  // In fix mode, prior AI context should NOT appear
  assert.ok(!ctx.includes("PRIOR AI COMMAND:"));
}

// Fix mode without lastFailure — should not emit FIX label
{
  const ctx = buildContextBlock({
    mode: "fix",
    recentHistory: "",
    gitSummary: "",
    lastFailure: "",
    lastStderr: "",
    priorAi: { prompt: "", command: "" },
  });
  assert.ok(!ctx.includes("MODE: FIX"));
  assert.equal(ctx, "");
}

// Refine mode without prior command — should not emit REFINE label
{
  const ctx = buildContextBlock({
    mode: "refine",
    recentHistory: "",
    gitSummary: "",
    lastFailure: "",
    lastStderr: "",
    priorAi: { prompt: "old prompt", command: "" },
  });
  assert.ok(!ctx.includes("MODE: REFINE"));
  assert.ok(!ctx.includes("PRIOR AI COMMAND:"));
}

// Chain mode
{
  const ctx = buildContextBlock({
    mode: "chain",
    recentHistory: "",
    gitSummary: "",
    lastFailure: "",
    lastStderr: "",
    priorAi: { prompt: "list ts files", command: "fd -e ts" },
  });
  assert.ok(ctx.includes("PRIOR AI COMMAND: fd -e ts"));
  assert.ok(ctx.includes("PRIOR PROMPT: list ts files"));
  assert.ok(ctx.includes("MODE: CHAIN"));
}

// Chain mode without prior command — should not emit CHAIN label
{
  const ctx = buildContextBlock({
    mode: "chain",
    recentHistory: "",
    gitSummary: "",
    lastFailure: "",
    lastStderr: "",
    priorAi: { prompt: "", command: "" },
  });
  assert.ok(!ctx.includes("MODE: CHAIN"));
}

// Generate mode with only history, no git
{
  const ctx = buildContextBlock({
    mode: "generate",
    recentHistory: "cd /tmp\nls",
    gitSummary: "",
    lastFailure: "",
    lastStderr: "",
    priorAi: { prompt: "", command: "" },
  });
  assert.ok(ctx.includes("RECENT COMMANDS:"));
  assert.ok(!ctx.includes("GIT:"));
}

// ── parseInput edge cases ───────────────────────────────────────────
// JSON with unknown extra keys (should not crash, should preserve known fields)
{
  const input = parseInput(JSON.stringify({
    prompt: "hello",
    mode: "generate",
    recentHistory: "",
    gitSummary: "",
    lastFailure: "",
    priorAi: { prompt: "", command: "" },
    unknownField: "ignored",
  }));
  assert.equal(input.prompt, "hello");
  assert.equal(input.mode, "generate");
}

// JSON with wrong types for fields (should fall back to defaults)
{
  const input = parseInput(JSON.stringify({
    prompt: 42,
    mode: null,
    recentHistory: false,
    gitSummary: [],
    lastFailure: {},
    lastStderr: 123,
    priorAi: "not-an-object",
  }));
  assert.equal(input.prompt, "");
  assert.equal(input.mode, "generate");
  assert.equal(input.recentHistory, "");
  assert.equal(input.gitSummary, "");
  assert.equal(input.lastFailure, "");
  assert.equal(input.lastStderr, "");
  assert.equal(input.priorAi.prompt, "");
  assert.equal(input.priorAi.command, "");
}

// ── loadConfig with context and ui (SAM-44) ─────────────────────────
const originalEnv = {
  COPILOT_ZLE_CONFIG_FILE: process.env.COPILOT_ZLE_CONFIG_FILE,
  COPILOT_ZLE_MODEL: process.env.COPILOT_ZLE_MODEL,
  COPILOT_ZLE_TOOL_TIMEOUT_MS: process.env.COPILOT_ZLE_TOOL_TIMEOUT_MS,
};

process.env.COPILOT_ZLE_CONFIG_FILE = new URL("./config.json", import.meta.url).pathname;
process.env.COPILOT_ZLE_MODEL = "";
process.env.COPILOT_ZLE_TOOL_TIMEOUT_MS = "100";

const config = loadConfig();
assert.equal(config.model.default, "gpt-5-mini");
assert.equal(config.limits.toolTimeoutMs, 4000);
// SAM-44: context and ui defaults
assert.equal(config.context.recentHistoryCount, 5);
assert.equal(config.context.includeGitSummary, true);
assert.equal(config.context.includeLastFailure, true);
assert.equal(config.ui.highlightAiBuffer, true);
assert.equal(config.ui.highlightStyle, "underline");
assert.equal(config.branding.productName, "ghostline-zle");
assert.equal(config.branding.statusPrefix, "[GHOSTLINE]");
assert.equal(config.branding.thinkingLabel, "WHISPERING");

if (typeof originalEnv.COPILOT_ZLE_CONFIG_FILE === "string") {
  process.env.COPILOT_ZLE_CONFIG_FILE = originalEnv.COPILOT_ZLE_CONFIG_FILE;
} else {
  delete process.env.COPILOT_ZLE_CONFIG_FILE;
}

if (typeof originalEnv.COPILOT_ZLE_MODEL === "string") {
  process.env.COPILOT_ZLE_MODEL = originalEnv.COPILOT_ZLE_MODEL;
} else {
  delete process.env.COPILOT_ZLE_MODEL;
}

if (typeof originalEnv.COPILOT_ZLE_TOOL_TIMEOUT_MS === "string") {
  process.env.COPILOT_ZLE_TOOL_TIMEOUT_MS = originalEnv.COPILOT_ZLE_TOOL_TIMEOUT_MS;
} else {
  delete process.env.COPILOT_ZLE_TOOL_TIMEOUT_MS;
}

// ── loadConfig: invalid/missing config file falls back to defaults ───
{
  const savedConfigFile = process.env.COPILOT_ZLE_CONFIG_FILE;
  process.env.COPILOT_ZLE_CONFIG_FILE = "/nonexistent/path/config.json";
  const fallbackConfig = loadConfig();
  assert.equal(fallbackConfig.model.default, "gpt-5-mini");
  assert.equal(fallbackConfig.context.recentHistoryCount, 5);
  assert.equal(fallbackConfig.ui.highlightStyle, "underline");
  assert.equal(fallbackConfig.branding.productName, "ghostline-zle");
  if (typeof savedConfigFile === "string") {
    process.env.COPILOT_ZLE_CONFIG_FILE = savedConfigFile;
  } else {
    delete process.env.COPILOT_ZLE_CONFIG_FILE;
  }
}

console.log("copilot-zle helper tests passed");
