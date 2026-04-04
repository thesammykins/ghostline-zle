import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadConfig } from "./config.mjs";
import {
  detectIntentMode,
  parseAliasContext,
  rankCommandCandidates,
} from "./logic.mjs";
import { queryRelevant, queryFollowUps, buildFewShotBlock, recordGeneration } from "./flight-log.mjs";
import { sniffProjectContext, buildProjectBlock } from "./project-context.mjs";

const TOOL_BLOCK_MESSAGE = "Tool use is disabled. Return only the command.";
const TOOL_DEVOPS_MESSAGE = "Dev/Ops tools require opt-in.";

const helperDir = path.dirname(fileURLToPath(import.meta.url));
const repoDir = path.dirname(helperDir);
const policyPath =
  process.env.COPILOT_ZLE_POLICY_FILE || path.join(repoDir, "policy.txt");
const sdkSessionPath = path.join(
  repoDir,
  "node_modules",
  "@github",
  "copilot-sdk",
  "dist",
  "session.js"
);

const ensureSdkCompatibilityPatch = () => {
  try {
    const sdkPkgPath = path.join(
      repoDir,
      "node_modules",
      "@github",
      "copilot-sdk",
      "package.json"
    );
    if (!fs.existsSync(sdkPkgPath)) return;
    const sdkPkg = JSON.parse(fs.readFileSync(sdkPkgPath, "utf8"));
    const version = sdkPkg.version || "";
    // Only patch known-affected versions (0.1.x series)
    if (!version.startsWith("0.1.")) return;
    if (!fs.existsSync(sdkSessionPath)) return;
    const content = fs.readFileSync(sdkSessionPath, "utf8");
    const brokenImport = 'from "vscode-jsonrpc/node";';
    if (!content.includes(brokenImport)) return;
    const patched = content.replace(
      brokenImport,
      'from "vscode-jsonrpc/node.js";'
    );
    if (patched !== content) {
      fs.writeFileSync(sdkSessionPath, patched, "utf8");
    }
  } catch {
    // Best effort patching only.
  }
};

const loadPolicy = () => {
  try {
    if (!fs.existsSync(policyPath)) return "";
    const content = fs.readFileSync(policyPath, "utf8").trim();
    return content.length > 0 ? content : "";
  } catch {
    return "";
  }
};

const loadUserTemplates = () => {
  const candidates = [
    process.env.COPILOT_ZLE_TEMPLATES_FILE,
    path.join(process.env.HOME || "", ".config", "copilot-zle", "templates.txt"),
  ].filter(Boolean);

  for (const filePath of candidates) {
    try {
      if (fs.existsSync(filePath)) {
        const content = fs.readFileSync(filePath, "utf8").trim();
        if (content.length > 0) return content;
      }
    } catch {
      continue;
    }
  }
  return "";
};

const getModelId = (model) => {
  if (!model || typeof model !== "object") return "";
  if (typeof model.id === "string" && model.id.length > 0) return model.id;
  if (typeof model.name === "string" && model.name.length > 0) return model.name;
  return "";
};

export const classifyError = (error) => {
  const message = error instanceof Error ? error.message : String(error || "copilot_error");
  const normalized = message.toLowerCase();

  if (
    normalized.includes("vscode-jsonrpc/node") ||
    normalized.includes("err_module_not_found")
  ) {
    return { error: message, error_code: "copilot_sdk_runtime_incompatible" };
  }

  if (normalized.includes("timeout") || normalized.includes("timed out")) {
    return { error: message, error_code: "copilot_timeout" };
  }
  if (
    normalized.includes("model") &&
    (normalized.includes("not found") ||
      normalized.includes("unsupported") ||
      normalized.includes("invalid") ||
      normalized.includes("rejected"))
  ) {
    return { error: message, error_code: "copilot_model_rejected" };
  }
  if (
    normalized.includes("enoent") ||
    normalized.includes("not found") ||
    normalized.includes("command not found") ||
    normalized.includes("executable")
  ) {
    return { error: message, error_code: "copilot_cli_missing" };
  }
  if (
    normalized.includes("login") ||
    normalized.includes("auth") ||
    normalized.includes("sign in") ||
    normalized.includes("unauthorized") ||
    normalized.includes("forbidden")
  ) {
    return { error: message, error_code: "copilot_auth_required" };
  }
  if (normalized.includes("copilot")) {
    return { error: message, error_code: "copilot_error" };
  }

  return { error: message, error_code: "copilot_error" };
};

const systemPrompt = ({
  cwd,
  dotfiles,
  home,
  inGitRepo,
  os,
  shell,
  termProgram,
  policy,
  userTemplates,
  intentMode,
  aliasContext,
  contextBlock,
}) => `You are a strict CLI command generator for macOS zsh.
Your ONLY job is to translate natural language into a single, valid, raw shell command.

ENVIRONMENT:
- OS: ${os}
- Shell: ${shell}
- Terminal: ${termProgram}
- Home: ${home}
- PWD: ${cwd}
- Dotfiles: ${dotfiles}
- In git repo: ${inGitRepo ? "yes" : "no"}
- Intent mode: ${intentMode}
- Aliases: ${Object.keys(aliasContext).length > 0 ? Object.entries(aliasContext).map(([k, v]) => `${k}=${v}`).join(", ") : "none"}

RULES:
1. NEVER explain. NEVER use markdown. NEVER use backticks.
2. Output exactly one command and nothing else.
3. THINK about the environment before answering. Use macOS flags, not Linux (e.g., stat -f%z not stat -c%s, pbcopy not xclip).
4. Prefer modern Rust CLI tools when available: fd over find, rg over grep, eza over ls, bat over cat, dust over du. These are standard on this system.
5. If the prompt implies "here" or "this directory", use the PWD provided — do not default to $HOME.
6. Prefer standard macOS paths (e.g., ~/Downloads, ~/Desktop) when the user mentions them by name.
7. Prefer readable output and avoid truncated fields when better alternatives exist.
8. Avoid unnecessary pipes if a single command/flag can do the job.
9. If common utilities are aliased, prefer command <utility> to bypass alias side-effects when clarity matters.
10. In inspect mode, prefer read-only commands.
11. If user intent is delete/destructive, still output one command, but it must be for manual execution only and never assume auto-run.

EXAMPLES:
User: list files larger than 10MB in downloads
Command: fd -t f -S +10m . ~/Downloads

User: kill process listening on port 8080
Command: lsof -ti:8080 | xargs kill

User: find text 'TODO' in python files here
Command: rg 'TODO' -g '*.py'

User: list all folders with sizes
Command: dust -d 1

User: show running docker containers
Command: docker ps
${policy ? `\n\n${policy}` : ""}${userTemplates ? `\n\nUSER TEMPLATES:\n${userTemplates}` : ""}${contextBlock || ""}`;

const makeErrorPayload = ({ model, ...errorPayload }) => ({
  command: "",
  confidence: 0,
  provider: "copilot",
  model,
  ...errorPayload,
});

const disconnectSession = async (session) => {
  if (!session) return;
  if (typeof session.disconnect === "function") {
    await session.disconnect().catch(() => undefined);
    return;
  }
  if (typeof session.destroy === "function") {
    await session.destroy().catch(() => undefined);
  }
};

export class CopilotService {
  constructor({ model = "gpt-5-mini", timeoutMs = 30000 } = {}) {
    this.model = model;
    this.timeoutMs = timeoutMs;
    this.client = null;
    this.approveAll = null;
    this.getAllowlist = null;
    this.getAvailableTools = null;
    this.isDevopsTool = null;
    this.supportedModelIds = new Set();
    this.started = false;
    this._starting = null;
  }

  async start() {
    if (this.started) return;
    if (this._starting) return this._starting;
    this._starting = this._doStart();
    return this._starting;
  }

  async _doStart() {
    try {
      ensureSdkCompatibilityPatch();

      try {
        const sdk = await import("@github/copilot-sdk");
        this.CopilotClient = sdk.CopilotClient;
        this.approveAll = sdk.approveAll;
      } catch (error) {
        throw new Error(classifyError(error).error);
      }

      try {
        const toolsModule = await import("../tools/index.mjs");
        this.getAllowlist = toolsModule.getAllowlist;
        this.getAvailableTools = toolsModule.getAvailableTools;
        this.isDevopsTool = toolsModule.isDevopsTool;
      } catch (error) {
        throw new Error(classifyError(error).error);
      }

      this.client = new this.CopilotClient();
      await this.client.start();

      const availableModels = await this.client.listModels();
      this.supportedModelIds = new Set(
        availableModels.map(getModelId).filter(Boolean)
      );
      this.started = true;
    } finally {
      this._starting = null;
    }
  }

  async stop() {
    if (!this.client) return;
    try {
      const cleanupErrors = await this.client.stop();
      if (Array.isArray(cleanupErrors) && cleanupErrors.length > 0) {
        throw cleanupErrors[0];
      }
    } catch {
      await this.client.forceStop().catch(() => undefined);
    }
    this.client = null;
    this.started = false;
  }

  async suggest({
    lastCommand,
    exitCode,
    cwd,
    home,
    recentHistory,
    model,
  }) {
    const requestModel =
      typeof model === "string" && model.trim().length > 0
        ? model.trim()
        : this.model;

    if (!this.started) {
      try {
        await this.start();
      } catch (error) {
        return makeErrorPayload({
          model: requestModel,
          ...classifyError(error),
        });
      }
    }

    if (!this.supportedModelIds.has(requestModel)) {
      return makeErrorPayload({
        model: requestModel,
        error: `Unsupported model: ${requestModel}`,
        error_code: "copilot_model_rejected",
      });
    }

    const resolvedCwd = cwd || process.env.PWD || process.cwd();
    const resolvedHome = home || process.env.HOME || "";

    // Enrich with project context
    let projectHint = "";
    const config = loadConfig();
    if (config.context.includeProjectInfo !== false) {
      try {
        const projectCtx = sniffProjectContext(resolvedCwd);
        if (projectCtx) {
          projectHint = buildProjectBlock(projectCtx);
        }
      } catch {
        // Best effort
      }
    }

    // Enrich with flight log follow-ups
    let followUpHint = "";
    if (config.flightLog.enabled && lastCommand) {
      try {
        const followUps = queryFollowUps({ command: lastCommand, limit: 3 });
        if (followUps.length > 0) {
          followUpHint = `\nFREQUENT FOLLOW-UPS after "${lastCommand}":\n${followUps.map((f) => `- ${f.command} (${f.count}x)`).join("\n")}`;
        }
      } catch {
        // Best effort
      }
    }

    const suggestPrompt = `You are a shell command predictor. Based on the user's recent command history and current directory, predict the single most likely next command they will run. Output ONLY the raw command, nothing else. No explanation, no markdown, no backticks.

CONTEXT:
- PWD: ${resolvedCwd}
- Home: ${resolvedHome}
- Last command: ${lastCommand || "none"} (exit ${exitCode ?? 0})
${recentHistory ? `- Recent history:\n${recentHistory}` : ""}${projectHint}${followUpHint}

Predict the next command:`;

    let session;
    try {
      session = await this.client.createSession({
        model: requestModel,
        onPermissionRequest: this.approveAll,
        workingDirectory: resolvedCwd,
        systemMessage: {
          mode: "append",
          content: suggestPrompt,
        },
      });

      const response = await session.sendAndWait(
        { prompt: "What command will the user run next?" },
        10000
      );
      const content = response?.data?.content ?? "";
      const { sanitizeCommand } = await import("./copilot-helper.mjs");
      const command = sanitizeCommand(content);

      return {
        command,
        confidence: command ? 0.7 : 0,
        provider: "copilot",
        model: requestModel,
      };
    } catch (error) {
      return makeErrorPayload({
        model: requestModel,
        ...classifyError(error),
      });
    } finally {
      await disconnectSession(session);
    }
  }

  async request({
    prompt,
    timeoutMs,
    model,
    cwd,
    home,
    dotfiles,
    shell,
    termProgram,
    inGitRepo,
    aliasContextRaw,
    contextBlock,
  }) {
    const requestModel =
      typeof model === "string" && model.trim().length > 0
        ? model.trim()
        : this.model;
    const effectiveTimeout = Number.isFinite(timeoutMs)
      ? timeoutMs
      : this.timeoutMs;

    if (!prompt || typeof prompt !== "string" || prompt.trim().length === 0) {
      return makeErrorPayload({ model: requestModel, error: "empty_prompt" });
    }

    if (!this.started) {
      try {
        await this.start();
      } catch (error) {
        return makeErrorPayload({
          model: requestModel,
          ...classifyError(error),
        });
      }
    }

    if (!this.supportedModelIds.has(requestModel)) {
      return {
        command: "",
        confidence: 0,
        provider: "copilot",
        model: requestModel,
        error: `Unsupported Copilot model: ${requestModel}`,
        error_code: "copilot_model_rejected",
        available_models: Array.from(this.supportedModelIds).sort(),
      };
    }

    const resolvedCwd = cwd || process.env.PWD || process.cwd();
    const resolvedHome = home || process.env.HOME || "";
    const resolvedDotfiles =
      dotfiles || process.env.DOTFILES || (resolvedHome ? `${resolvedHome}/.dotfiles` : "");
    const resolvedShell = shell || process.env.SHELL || "zsh";
    const resolvedTermProgram = termProgram || process.env.TERM_PROGRAM || "unknown";
    const resolvedInGitRepo =
      inGitRepo === true ||
      inGitRepo === "true" ||
      inGitRepo === "1" ||
      fs.existsSync(path.join(resolvedCwd, ".git"));
    const resolvedOs = `${process.platform} (${process.arch})`;
    const aliasContext = parseAliasContext(aliasContextRaw || "");
    const intentMode = detectIntentMode(prompt);

    const policy = loadPolicy();
    const userTemplates = loadUserTemplates();
    const config = loadConfig();
    const allowlist = this.getAllowlist();
    const tools = this.getAvailableTools();
    const devopsEnabled = config.tools.devopsEnabled;
    const skipTools = allowlist.size === 0;

    // Flight log: inject few-shot examples from past successes
    let fewShotBlock = "";
    if (config.flightLog.enabled && config.flightLog.fewShotCount > 0) {
      try {
        const relevant = queryRelevant({
          prompt,
          cwd: resolvedCwd,
          mode: intentMode,
          limit: config.flightLog.fewShotCount,
        });
        fewShotBlock = buildFewShotBlock(relevant);
      } catch {
        // Best effort — don't block generation
      }
    }

    // Project context: detect project type, scripts, targets
    let projectBlock = "";
    if (config.context.includeProjectInfo !== false) {
      try {
        const projectCtx = sniffProjectContext(resolvedCwd);
        projectBlock = buildProjectBlock(projectCtx);
      } catch {
        // Best effort
      }
    }

    let session;
    try {
      session = await this.client.createSession({
        model: requestModel,
        onPermissionRequest: this.approveAll,
        workingDirectory: resolvedCwd,
        systemMessage: {
          mode: "append",
          content: systemPrompt({
            cwd: resolvedCwd,
            dotfiles: resolvedDotfiles,
            home: resolvedHome,
            inGitRepo: resolvedInGitRepo,
            os: resolvedOs,
            shell: resolvedShell,
            termProgram: resolvedTermProgram,
            policy,
            userTemplates,
            intentMode,
            aliasContext,
            contextBlock: (contextBlock || "") + projectBlock + fewShotBlock,
          }),
        },
        availableTools: skipTools ? undefined : Array.from(allowlist),
        tools: skipTools ? [] : tools,
        hooks: {
          onPreToolUse: async ({ toolName }) => {
            if (!allowlist.has(toolName)) {
              return {
                permissionDecision: "deny",
                additionalContext: TOOL_BLOCK_MESSAGE,
              };
            }
            if (this.isDevopsTool(toolName) && !devopsEnabled) {
              return {
                permissionDecision: "deny",
                additionalContext: TOOL_DEVOPS_MESSAGE,
              };
            }
            return {
              permissionDecision: "allow",
            };
          },
        },
      });

      const response = await session.sendAndWait(
        { prompt },
        effectiveTimeout
      );
      const content = response?.data?.content ?? "";
      const ranked = rankCommandCandidates({
        rawCommand: content,
        aliasContext,
        intentMode,
        userPrompt: prompt,
      });

      return {
        command: ranked.command,
        confidence: ranked.command ? 1 : 0,
        provider: "copilot",
        model: requestModel,
        intent_mode: intentMode,
        candidates: ranked.candidates,
      };
    } catch (error) {
      return makeErrorPayload({
        model: requestModel,
        ...classifyError(error),
      });
    } finally {
      await disconnectSession(session);
    }
  }

  recordResult({ command, prompt, mode, cwd, durationMs }) {
    try {
      const config = loadConfig();
      if (!config.flightLog.enabled) return;
      recordGeneration({
        prompt,
        command,
        mode,
        cwd,
        durationMs,
        maxEntries: config.flightLog.maxEntries,
      });
    } catch {
      // Best effort
    }
  }

  async explain({ command, model, cwd, home }) {
    const requestModel =
      typeof model === "string" && model.trim().length > 0
        ? model.trim()
        : this.model;

    if (!command || typeof command !== "string" || command.trim().length === 0) {
      return { explanation: "", error: "empty_command" };
    }

    if (!this.started) {
      try {
        await this.start();
      } catch (error) {
        return { explanation: "", ...classifyError(error) };
      }
    }

    if (!this.supportedModelIds.has(requestModel)) {
      return {
        explanation: "",
        error: `Unsupported model: ${requestModel}`,
        error_code: "copilot_model_rejected",
      };
    }

    const resolvedCwd = cwd || process.env.PWD || process.cwd();
    const resolvedHome = home || process.env.HOME || "";

    const explainPrompt = `You explain shell commands. Given a command, output a single terse line explaining what it does. Terse technical voice: direct, no emoji.

RULES:
1. Output exactly ONE line of explanation. No markdown, no backticks.
2. Start with the verb (LISTS, FINDS, KILLS, SHOWS, etc.).
3. Mention key flags and their effect.
4. Be brief — max 80 characters if possible.
5. If the command is destructive, note it: "[DESTRUCTIVE]" prefix.

EXAMPLES:
Command: fd -t f -S +10m . ~/Downloads
Explanation: FINDS FILES OVER 10MB IN ~/Downloads

Command: lsof -ti:8080 | xargs kill
Explanation: KILLS PROCESSES LISTENING ON PORT 8080

Command: rm -rf /tmp/build
Explanation: [DESTRUCTIVE] REMOVES /tmp/build RECURSIVELY WITHOUT CONFIRMATION

Explain this command:
${command.trim()}`;

    let session;
    try {
      session = await this.client.createSession({
        model: requestModel,
        onPermissionRequest: this.approveAll,
        workingDirectory: resolvedCwd,
        systemMessage: {
          mode: "append",
          content: explainPrompt,
        },
      });

      const response = await session.sendAndWait(
        { prompt: `Explain: ${command.trim()}` },
        10000
      );
      const content = (response?.data?.content ?? "").trim();
      // Strip markdown/backticks if model misbehaves
      const cleaned = content
        .replace(/^```[\s\S]*?```$/gm, "")
        .replace(/`/g, "")
        .split("\n")[0]
        .trim();

      return { explanation: cleaned || "NO EXPLANATION AVAILABLE" };
    } catch (error) {
      return { explanation: "", ...classifyError(error) };
    } finally {
      await disconnectSession(session);
    }
  }
}
