import { defineTool } from "@github/copilot-sdk";
import { loadConfig } from "../config.mjs";
import {
  denyResult,
  failureResult,
  getToolContext,
  joinResults,
  normalizeAllowlist,
  readTextFileSafe,
  resolveScopedPath,
  runCommand,
  validateToken,
} from "./utils.mjs";

const toolContext = getToolContext();
const config = loadConfig();
const devopsEnabled = config.tools.devopsEnabled;

const TOOL_DEFINITIONS = {
  sys_info: defineTool("sys_info", {
    description: "System information (uname, sw_vers, sysctl).",
    handler: async () => {
      const parts = await Promise.all([
        runCommand("uname", ["-a"]),
        runCommand("sw_vers", []),
        runCommand("sysctl", ["hw.model", "hw.memsize", "hw.ncpu"]),
      ]);
      return joinResults(parts);
    },
  }),
  disk_usage: defineTool("disk_usage", {
    description: "Disk usage and disks list.",
    handler: async () => {
      const parts = await Promise.all([
        runCommand("df", ["-h"]),
        runCommand("diskutil", ["list"]),
      ]);
      return joinResults(parts);
    },
  }),
  process_list: defineTool("process_list", {
    description: "List processes with memory and command.",
    handler: async () => runCommand("ps", ["-axo", "pid,ppid,rss,command,%mem"]),
  }),
  network_ports: defineTool("network_ports", {
    description: "List open network ports.",
    handler: async () => runCommand("lsof", ["-i", "-P", "-n"]),
  }),
  list_files: defineTool("list_files", {
    description: "List files in a directory (CWD + HOME only).",
    parameters: {
      type: "object",
      properties: {
        dir: { type: "string" },
      },
      required: ["dir"],
      additionalProperties: false,
    },
    handler: async ({ dir }) => {
      try {
        const scoped = resolveScopedPath(dir, toolContext);
        return runCommand("ls", ["-la", scoped]);
      } catch (error) {
        return denyResult(error instanceof Error ? error.message : "PATH_OUTSIDE_SCOPE");
      }
    },
  }),
  read_file: defineTool("read_file", {
    description: "Read a UTF-8 text file (max 1MB, CWD + HOME only).",
    parameters: {
      type: "object",
      properties: {
        path: { type: "string" },
      },
      required: ["path"],
      additionalProperties: false,
    },
    handler: async ({ path }) => readTextFileSafe(path, { context: toolContext }),
  }),
  search_text: defineTool("search_text", {
    description: "Search text using ripgrep (scoped).",
    parameters: {
      type: "object",
      properties: {
        pattern: { type: "string" },
        path: { type: "string" },
      },
      required: ["pattern", "path"],
      additionalProperties: false,
    },
    handler: async ({ pattern, path }) => {
      try {
        const scoped = resolveScopedPath(path, toolContext);
        if (typeof pattern !== "string" || pattern.trim().length === 0) {
          return failureResult("INVALID_PATTERN");
        }
        return runCommand("rg", [pattern, scoped]);
      } catch (error) {
        return denyResult(error instanceof Error ? error.message : "PATH_OUTSIDE_SCOPE");
      }
    },
  }),
  git_status: defineTool("git_status", {
    description: "Show git status (short).",
    handler: async () => runCommand("git", ["status", "-sb"]),
  }),
  git_branch: defineTool("git_branch", {
    description: "Show current git branch.",
    handler: async () => runCommand("git", ["rev-parse", "--abbrev-ref", "HEAD"]),
  }),
  docker_ps: defineTool("docker_ps", {
    description: "List running Docker containers.",
    handler: async () => runCommand("docker", ["ps"]),
  }),
  kubectl_get: defineTool("kubectl_get", {
    description: "Get a Kubernetes resource.",
    parameters: {
      type: "object",
      properties: {
        resource: { type: "string" },
        namespace: { type: "string" },
      },
      required: ["resource", "namespace"],
      additionalProperties: false,
    },
    handler: async ({ resource, namespace }) => {
      try {
        const safeResource = validateToken(resource, "RESOURCE");
        const safeNamespace = validateToken(namespace, "NAMESPACE");
        return runCommand("kubectl", ["get", safeResource, "-n", safeNamespace]);
      } catch (error) {
        return failureResult(error instanceof Error ? error.message : "INVALID_RESOURCE");
      }
    },
  }),
  aws_identity: defineTool("aws_identity", {
    description: "Get AWS caller identity.",
    handler: async () => runCommand("aws", ["sts", "get-caller-identity"]),
  }),
};

const devopsTools = new Set([
  "git_status",
  "git_branch",
  "docker_ps",
  "kubectl_get",
  "aws_identity",
]);

export const getAvailableTools = () => {
  const allowlist = normalizeAllowlist(config.tools.allowlist);
  const selected = [];
  const allowedSet = new Set(allowlist);
  for (const [name, tool] of Object.entries(TOOL_DEFINITIONS)) {
    if (!allowedSet.has(name)) {
      continue;
    }
    if (devopsTools.has(name) && !devopsEnabled) {
      continue;
    }
    selected.push(tool);
  }
  return selected;
};

export const getAllowlist = () =>
  new Set(normalizeAllowlist(config.tools.allowlist));

export const isDevopsTool = (name) => devopsTools.has(name);
