import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const TOOL_BLOCK_MESSAGE = "Tool use is disabled. Return only the command.";
const TOOL_DEVOPS_MESSAGE = "Dev/Ops tools require opt-in.";

const helperDir = path.dirname(fileURLToPath(import.meta.url));
const repoDir = path.dirname(helperDir);
const sdkSessionPath = path.join(
  repoDir,
  "node_modules",
  "@github",
  "copilot-sdk",
  "dist",
  "session.js"
);

export const ensureSdkCompatibilityPatch = () => {
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

export const getModelId = (model) => {
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

export const disconnectSession = async (session) => {
  if (!session || typeof session.disconnect !== "function") return;
  await session.disconnect().catch(() => undefined);
};

export const waitForSessionIdle = async (session, options, timeoutMs) => {
  let resolveIdle;
  let rejectIdle;
  let lastAssistantMessage;
  let timeoutId;

  const idlePromise = new Promise((resolve, reject) => {
    resolveIdle = resolve;
    rejectIdle = reject;
  });

  const unsubscribe = session.on((event) => {
    if (event.type === "assistant.message") {
      lastAssistantMessage = event;
      return;
    }

    if (event.type === "session.idle") {
      resolveIdle();
      return;
    }

    if (event.type === "session.error") {
      const error = new Error(event.data.message);
      error.stack = event.data.stack;
      rejectIdle(error);
    }
  });

  try {
    await session.send(options);

    if (Number.isFinite(timeoutMs) && timeoutMs > 0) {
      const timeoutPromise = new Promise((_, reject) => {
        timeoutId = setTimeout(() => {
          reject(new Error(`Timeout after ${timeoutMs}ms waiting for session.idle`));
        }, timeoutMs);
      });
      await Promise.race([idlePromise, timeoutPromise]);
    } else {
      await idlePromise;
    }

    return lastAssistantMessage;
  } finally {
    if (timeoutId !== undefined) {
      clearTimeout(timeoutId);
    }
    unsubscribe();
  }
};

export const buildSessionTooling = ({ allowlist, tools, devopsEnabled, isDevopsTool }) => {
  if (!(allowlist instanceof Set) || allowlist.size === 0) {
    return {
      availableTools: undefined,
      tools: [],
      hooks: undefined,
    };
  }

  return {
    availableTools: Array.from(allowlist),
    tools,
    hooks: {
      onPreToolUse: async ({ toolName }) => {
        if (!allowlist.has(toolName)) {
          return {
            permissionDecision: "deny",
            additionalContext: TOOL_BLOCK_MESSAGE,
          };
        }
        if (typeof isDevopsTool === "function" && isDevopsTool(toolName) && !devopsEnabled) {
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
  };
};
