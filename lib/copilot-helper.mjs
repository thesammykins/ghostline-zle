import { CopilotClient, approveAll } from "@github/copilot-sdk";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadConfig } from "./config.mjs";
import {
  buildSessionTooling,
  classifyError,
  disconnectSession,
  waitForSessionIdle,
} from "./copilot-runtime.mjs";
import { detectIntentMode, parseAliasContext, rankCommandCandidates } from "./logic.mjs";
import { resolvePatternCommand } from "./patterns.mjs";
import { getAllowlist, getAvailableTools, isDevopsTool } from "../tools/index.mjs";

const TIMEOUT_MS = Number.parseInt(process.env.COPILOT_ZLE_TIMEOUT_MS || "30000", 10);
const DEBUG = process.env.COPILOT_ZLE_DEBUG === "1";

const debugLog = (...args) => {
  if (!DEBUG) return;
  const ts = new Date().toISOString();
  process.stderr.write(`[COPILOT DEBUG ${ts}] ${args.join(" ")}\n`);
};

const helperDir = path.dirname(fileURLToPath(import.meta.url));
const repoDir = path.dirname(helperDir);
const isDirectRun = process.argv[1]
  ? path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
  : false;
const policyPath =
  process.env.COPILOT_ZLE_POLICY_FILE || path.join(repoDir, "policy.txt");

const loadPolicy = () => {
  try {
    if (!fs.existsSync(policyPath)) return "";
    const content = fs.readFileSync(policyPath, "utf8").trim();
    return content.length > 0 ? content : "";
  } catch {
    return "";
  }
};

// ── Input Parsing (SAM-39) ──────────────────────────────────────────
// Accepts JSON payload from the ZLE widget or raw text for backwards compat.
// Returns a normalized input object.
export const parseInput = (raw) => {
  const empty = {
    prompt: "",
    mode: "generate",
    model: "",
    recentHistory: "",
    gitSummary: "",
    lastFailure: "",
    lastStderr: "",
    cwd: "",
    home: "",
    dotfiles: "",
    shell: "",
    termProgram: "",
    inGitRepo: "",
    aliasContextRaw: "",
    priorAi: { prompt: "", command: "" },
  };
  if (!raw || typeof raw !== "string" || raw.trim().length === 0) return empty;

  const trimmed = raw.trim();
  // Try JSON first (structured payload from SAM-39 ZLE widget)
  if (trimmed.startsWith("{")) {
    try {
      const parsed = JSON.parse(trimmed);
      return {
        prompt: typeof parsed.prompt === "string" ? parsed.prompt : "",
        mode: typeof parsed.mode === "string" ? parsed.mode : "generate",
        model: typeof parsed.model === "string" ? parsed.model : "",
        recentHistory: typeof parsed.recentHistory === "string" ? parsed.recentHistory : "",
        gitSummary: typeof parsed.gitSummary === "string" ? parsed.gitSummary : "",
        lastFailure: typeof parsed.lastFailure === "string" ? parsed.lastFailure : "",
        lastStderr: typeof parsed.lastStderr === "string" ? parsed.lastStderr : "",
        cwd: typeof parsed.cwd === "string" ? parsed.cwd : "",
        home: typeof parsed.home === "string" ? parsed.home : "",
        dotfiles: typeof parsed.dotfiles === "string" ? parsed.dotfiles : "",
        shell: typeof parsed.shell === "string" ? parsed.shell : "",
        termProgram: typeof parsed.termProgram === "string" ? parsed.termProgram : "",
        inGitRepo: typeof parsed.inGitRepo === "string" ? parsed.inGitRepo : "",
        aliasContextRaw: typeof parsed.aliasContextRaw === "string" ? parsed.aliasContextRaw : "",
        priorAi: {
          prompt: typeof parsed.priorAi?.prompt === "string" ? parsed.priorAi.prompt : "",
          command: typeof parsed.priorAi?.command === "string" ? parsed.priorAi.command : "",
        },
      };
    } catch {
      // Fall through to raw text handling
    }
  }

  // Raw text fallback (legacy or pipe usage)
  return { ...empty, prompt: trimmed };
};

// ── Context Block Builder (SAM-39) ──────────────────────────────────
// Builds the context section appended to the system prompt.
export const buildContextBlock = ({ mode, recentHistory, gitSummary, lastFailure, lastStderr, priorAi }) => {
  const parts = [];

  if (gitSummary) {
    parts.push(`GIT: ${gitSummary}`);
  }

  if (recentHistory) {
    parts.push(`RECENT COMMANDS:\n${recentHistory}`);
  }

  if (mode === "fix" && lastFailure) {
    parts.push(`FAILED COMMAND: ${lastFailure}`);
    if (lastStderr) {
      parts.push(`STDERR OUTPUT:\n${lastStderr}`);
    }
    parts.push("MODE: FIX. Analyze the failed command and output a corrected version. Consider common failure causes: typos, wrong flags, missing paths, permission issues.");
  } else if (mode === "refine" && priorAi?.command) {
    parts.push(`PRIOR AI COMMAND: ${priorAi.command}`);
    if (priorAi.prompt) {
      parts.push(`PRIOR PROMPT: ${priorAi.prompt}`);
    }
    parts.push("MODE: REFINE. Modify the prior command based on the new instruction. Keep unrelated parts unchanged.");
  } else if (mode === "chain" && priorAi?.command) {
    parts.push(`PRIOR AI COMMAND: ${priorAi.command}`);
    if (priorAi.prompt) {
      parts.push(`PRIOR PROMPT: ${priorAi.prompt}`);
    }
    parts.push("MODE: CHAIN. Extend the prior command based on the new instruction. Append a pipe, redirect, or logical operator to build on it. Output the FULL command including the prior part and the new extension. Do NOT replace — extend.");
  }

  if (parts.length === 0) return "";
  return `\nCONTEXT:\n${parts.join("\n")}`;
};

const systemPrompt = ({ cwd, dotfiles, home, inGitRepo, os, shell, termProgram, policy, context }) => `You are a strict CLI command generator for macOS zsh.
Your ONLY job is to translate natural language into a single, valid, raw shell command.

ENVIRONMENT:
- OS: ${os}
- Shell: ${shell}
- Terminal: ${termProgram}
- Home: ${home}
- PWD: ${cwd}
- Dotfiles: ${dotfiles}
- In git repo: ${inGitRepo ? "yes" : "no"}

RULES:
1. NEVER explain. NEVER use markdown. NEVER use backticks.
2. Output exactly one shell line and nothing else. Pipes, redirects, and logical operators (&&, ||, ;) are allowed within that single line. Multi-line output (backslash continuations, heredocs) is forbidden.
3. Prefer standard macOS paths (e.g., ~/Downloads, ~/Desktop) unless a local path is explicitly implied.
4. Use modern macOS/zsh idiomatic commands (e.g., find, rg, awk, lsof, ipconfig, pbcopy).
5. If the prompt implies your current location, use the PWD provided.
6. Prefer readable output and avoid truncated fields when better alternatives exist.
7. When using ps, prefer full command/args output (command/args) over comm when clarity matters.
8. Avoid unnecessary pipes if a single command/flag can do the job.
9. Prefer graceful signals (SIGTERM) over forceful ones (SIGKILL/kill -9) unless the user explicitly requests force.
10. Default to safe, non-destructive alternatives (list, dry-run, preview) when the intent is ambiguous.

EXAMPLES:
User: list files larger than 10MB in downloads
Command: find ~/Downloads -type f -size +10M

User: stop process listening on port 8080
Command: lsof -ti:8080 | xargs kill

User: find text 'TODO' in python files here
Command: rg 'TODO' -g '*.py'
${policy ? `\n\n${policy}` : ""}${context || ""}`;

const readStdin = async () =>
  new Promise((resolve, reject) => {
    let data = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => {
      data += chunk;
    });
    process.stdin.on("end", () => resolve(data.trim()));
    process.stdin.on("error", reject);
  });

export const sanitizeCommand = (value) => {
  if (typeof value !== "string") return "";
  let trimmed = value.trim();
  if (trimmed.length === 0) return "";
  if (/[\r\n]/.test(trimmed)) return "";
  if (trimmed.includes("```")) return "";
  trimmed = trimmed.replace(/^command:\s*/i, "");
  if (trimmed.length === 0) return "";
  // Block control characters but allow normal shell metacharacters (|, ;, &, >, <)
  if (/[\u0000-\u0008\u000E-\u001F\u007F]/.test(trimmed)) return "";
  // Block dangerous patterns: eval/exec injection, command nesting abuse
  if (/\beval\b/.test(trimmed)) return "";
  if (/`[^`]+`/.test(trimmed)) return "";
  return trimmed;
};

const safeJson = (payload) =>
  JSON.stringify(payload, (_key, val) => (typeof val === "string" ? val : val));

export const resolveModel = (config = loadConfig(), env = process.env) => {
  if (typeof env.COPILOT_ZLE_MODEL === "string" && env.COPILOT_ZLE_MODEL.trim().length > 0) {
    return env.COPILOT_ZLE_MODEL.trim();
  }
  if (config?.model && typeof config.model.default === "string" && config.model.default.trim().length > 0) {
    return config.model.default.trim();
  }
  return "gpt-5-mini";
};

const main = async () => {
  const raw = await readStdin();
  const config = loadConfig();
  const input = parseInput(raw);
  const model = typeof input.model === "string" && input.model.trim().length > 0
    ? input.model.trim()
    : resolveModel(config);

  debugLog(`MODE=${input.mode} MODEL=${model} PROMPT_LEN=${input.prompt.length}`);

  if (!input.prompt) {
    debugLog("ABORT: empty prompt");
    process.stdout.write(safeJson({
      command: "",
      confidence: 0,
      provider: "copilot",
      model,
      error: "empty_prompt",
    }));
    return;
  }

  const cwd = input.cwd || process.env.PWD || process.cwd();
  const home = input.home || process.env.HOME || "";
  const dotfiles = input.dotfiles || process.env.DOTFILES || (home ? `${home}/.dotfiles` : "");
  const shell = input.shell || process.env.SHELL || "zsh";
  const termProgram = input.termProgram || process.env.TERM_PROGRAM || "unknown";
  const inGitRepo =
    input.inGitRepo === "true" ||
    input.inGitRepo === "1" ||
    input.gitSummary.length > 0 ||
    fs.existsSync(path.join(cwd, ".git"));
  const os = `${process.platform} (${process.arch})`;
  const aliasContext = parseAliasContext(input.aliasContextRaw || "");
  const intentMode = detectIntentMode(input.prompt);

  const policy = loadPolicy();
  const context = buildContextBlock(input);
  const fastPathCommand = resolvePatternCommand({ prompt: input.prompt, mode: input.mode, cwd, home, dotfiles });

  debugLog(`CONTEXT_LEN=${context.length} POLICY_LEN=${policy.length} GIT=${input.gitSummary || "none"}`);
  if (input.mode === "fix") debugLog(`FIX_TARGET=${input.lastFailure}`);
  if (input.mode === "refine") debugLog(`REFINE_PRIOR=${input.priorAi.command}`);

  if (input.mode === "generate" && fastPathCommand) {
    debugLog(`FAST_PATH=1 CMD_LEN=${fastPathCommand.length}`);
    process.stdout.write(safeJson({
      command: fastPathCommand,
      candidates: [fastPathCommand],
      confidence: 1,
      provider: "copilot",
      model,
    }));
    return;
  }

  const client = new CopilotClient();
  const allowlist = getAllowlist();
  const tools = getAvailableTools();
  const devopsEnabled = config.tools.devopsEnabled;
  const tooling = buildSessionTooling({
    allowlist,
    tools,
    devopsEnabled,
    isDevopsTool,
  });
  let session;
  const t0 = Date.now();
  try {
    await client.start();

    // SAM-43: Removed listModels() from hot path. Model validation now
    // happens lazily — if the model is invalid, createSession or
    // sendAndWait will throw and classifyError handles it.

    session = await client.createSession({
      model,
      onPermissionRequest: approveAll,
      workingDirectory: cwd,
      systemMessage: {
        mode: "append",
        content: systemPrompt({ cwd, dotfiles, home, inGitRepo, os, shell, termProgram, policy, context }),
      },
      availableTools: tooling.availableTools,
      tools: tooling.tools,
      hooks: tooling.hooks,
    });

    // Main command generation should wait for an actual Copilot result or
    // session error; slow model responses are expected and shouldn't surface
    // as user-facing timeouts.
    const response = await waitForSessionIdle(session, { prompt: input.prompt });
    const latencyMs = Date.now() - t0;
    const content = response?.data?.content ?? "";
    const ranked = rankCommandCandidates({
      rawCommand: content,
      aliasContext,
      intentMode,
      userPrompt: input.prompt,
    });
    const command = ranked.command;

    const sanitized = content !== command;
    debugLog(`LATENCY=${latencyMs}ms RAW_LEN=${content.length} SANITIZED=${sanitized} CMD_LEN=${command.length}`);
    if (sanitized && content.length > 0) debugLog(`SANITIZE_ACTION: raw="${content.slice(0, 120)}"`);

    process.stdout.write(safeJson({
      command,
      candidates: ranked.candidates,
      confidence: command ? 1 : 0,
      provider: "copilot",
      model,
    }));
  } catch (error) {
    const latencyMs = Date.now() - t0;
    const classified = classifyError(error);
    debugLog(`ERROR LATENCY=${latencyMs}ms CODE=${classified.error_code} MSG=${classified.error}`);
    process.stdout.write(safeJson({
      command: "",
      confidence: 0,
      provider: "copilot",
      model,
      ...classified,
    }));
  } finally {
    await disconnectSession(session).catch(() => undefined);
    await client.stop().catch(() => undefined);
  }
};

if (isDirectRun) {
  main().catch((error) => {
    const config = loadConfig();
    const model = resolveModel(config);
    const classified = classifyError(error);
    process.stdout.write(safeJson({
      command: "",
      confidence: 0,
      provider: "copilot",
      model,
      ...classified,
    }));
  });
}
