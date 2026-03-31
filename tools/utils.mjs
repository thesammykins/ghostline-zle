import { execFile } from "node:child_process";
import fsSync from "node:fs";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { loadConfig } from "../lib/config.mjs";

const execFileAsync = promisify(execFile);

const config = loadConfig();
const MAX_OUTPUT_BYTES = config.limits.maxOutputBytes;
const MAX_FILE_BYTES = config.limits.maxFileBytes;
const TOOL_TIMEOUT_MS = config.limits.toolTimeoutMs;

const trimOutput = (value, maxBytes = MAX_OUTPUT_BYTES) => {
  if (typeof value !== "string") return "";
  const buffer = Buffer.from(value, "utf8");
  if (buffer.length <= maxBytes) return value.trim();
  const truncated = buffer.subarray(0, maxBytes).toString("utf8").trimEnd();
  return `${truncated}\nOUTPUT TRUNCATED`;
};

const expandHome = (value, home) => {
  if (value === "~") return home;
  if (value.startsWith("~/")) return path.join(home, value.slice(2));
  return value;
};

const isWithin = (base, target) => {
  const relative = path.relative(base, target);
  if (relative === "") return true;
  if (relative === "..") return false;
  return !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
};

export const getToolContext = () => ({
  cwd: process.env.PWD || process.cwd(),
  home: process.env.HOME || os.homedir(),
});

export const resolveScopedPath = (value, { cwd, home }) => {
  if (typeof value !== "string") {
    throw new Error("INVALID_PATH");
  }
  const trimmed = value.trim();
  if (trimmed.length === 0 || trimmed.includes("\u0000")) {
    throw new Error("INVALID_PATH");
  }
  const expanded = expandHome(trimmed, home);
  const resolved = path.isAbsolute(expanded)
    ? path.normalize(expanded)
    : path.resolve(cwd, expanded);
  if (!isWithin(cwd, resolved) && !isWithin(home, resolved)) {
    throw new Error("PATH_OUTSIDE_SCOPE");
  }
  // Resolve symlinks to prevent scope bypass (e.g., symlink -> /etc)
  let real;
  try {
    real = fsSync.realpathSync(resolved);
  } catch {
    // Path doesn't exist yet — allow creation within scope
    return resolved;
  }
  if (!isWithin(cwd, real) && !isWithin(home, real)) {
    throw new Error("PATH_OUTSIDE_SCOPE");
  }
  return real;
};

const formatExecError = (error, command) => {
  if (error && typeof error === "object") {
    if (error.code === "ENOENT") return `COMMAND_NOT_FOUND: ${command}`;
    if (error.killed) return "COMMAND_TIMEOUT";
    if (typeof error.message === "string" && error.message.length > 0) {
      return error.message;
    }
  }
  return "COMMAND_FAILED";
};

export const failureResult = (reason) => ({
  textResultForLlm: `ERROR: ${reason}`,
  resultType: "failure",
});

export const denyResult = (reason) => ({
  textResultForLlm: `DENIED: ${reason}`,
  resultType: "denied",
});

export const runCommand = async (command, args, options = {}) => {
  try {
    const { stdout, stderr } = await execFileAsync(command, args, {
      timeout: TOOL_TIMEOUT_MS,
      maxBuffer: MAX_OUTPUT_BYTES * 4,
      ...options,
    });
    const output = `${stdout}${stderr}`.trim();
    return trimOutput(output);
  } catch (error) {
    return failureResult(formatExecError(error, command));
  }
};

export const readTextFileSafe = async (filePath, options = {}) => {
  const context = options.context || getToolContext();
  const maxBytes = options.maxBytes || MAX_FILE_BYTES;
  let resolved;
  try {
    resolved = resolveScopedPath(filePath, context);
  } catch (error) {
    return denyResult(error instanceof Error ? error.message : "PATH_OUTSIDE_SCOPE");
  }

  let stat;
  try {
    stat = await fs.stat(resolved);
  } catch {
    return failureResult("NOT_FOUND");
  }

  if (!stat.isFile()) {
    return failureResult("NOT_A_FILE");
  }

  if (stat.size > maxBytes) {
    return failureResult("FILE_TOO_LARGE");
  }

  const buffer = await fs.readFile(resolved);
  if (buffer.length > maxBytes) {
    return failureResult("FILE_TOO_LARGE");
  }

  try {
    const text = new TextDecoder("utf-8", { fatal: true }).decode(buffer);
    return trimOutput(text);
  } catch {
    return failureResult("NON_UTF8_TEXT");
  }
};

export const normalizeAllowlist = (value) => {
  if (Array.isArray(value)) {
    return value
      .map((token) => (typeof token === "string" ? token.trim().toLowerCase() : ""))
      .filter((token) => token.length > 0);
  }
  if (typeof value !== "string") return [];
  return value
    .split(/[\s,]+/)
    .map((token) => token.trim().toLowerCase())
    .filter((token) => token.length > 0);
};

export const validateToken = (value, label) => {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new Error(`INVALID_${label}`);
  }
  const trimmed = value.trim();
  if (!/^[A-Za-z0-9._:-]+$/.test(trimmed)) {
    throw new Error(`INVALID_${label}`);
  }
  return trimmed;
};

export const joinResults = (parts) => {
  for (const part of parts) {
    if (typeof part !== "string") return part;
  }
  return parts
    .map((part) => part.trim())
    .filter((part) => part.length > 0)
    .join("\n");
};
