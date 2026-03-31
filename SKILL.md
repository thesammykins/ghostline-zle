# SKILL.md - Copilot ZLE Tool Extensibility

## Purpose

Extend the Copilot ZLE plugin with safe, read-only tools. The core contract remains: one raw shell line per response. Pipes, redirects, and logical operators (`&&`, `||`, `;`) within that single line are permitted. Multi-line output (backslash continuations, heredocs) is forbidden.

## Tool wiring

- Tools live in `./tools/`.
- Copilot path loads `tools/index.mjs` and `config.json`.
- Model default lives in `config.json` and can be overridden with `COPILOT_ZLE_MODEL`.
- SDK patch hook lives in `patch-copilot-sdk.mjs`.
- Env overrides: `COPILOT_ZLE_TOOLS_ALLOWLIST`, `COPILOT_ZLE_TOOLS_DEVOPS`, `COPILOT_ZLE_TOOL_MAX_OUTPUT_BYTES`, `COPILOT_ZLE_TOOL_MAX_FILE_BYTES`, `COPILOT_ZLE_TOOL_TIMEOUT_MS`.

## Baseline constraints

- Output: single shell line only. Pipes, redirects, and logical operators allowed within that line. No multi-line output. No markdown. No explanations.
- Default mode: tools disabled. Enable only via allowlist.
- Path scope: CWD + $HOME only.
- Model: Copilot should default to `gpt-5-mini`.
- Safety: prefer graceful signals and non-destructive alternatives by default.

## Safe extension pattern

1. Define tools with `defineTool`.
2. Pass an explicit allowlist into `createSession({ tools: [...] })`.
3. Keep `hooks.onPreToolUse` to deny non-allowlisted calls.
4. Enforce command-only output client-side. Reject multiline/prose.
5. Keep `systemMessage` mode as append unless you rebuild all guardrails.
6. Use config first; env overrides only when necessary.
7. Keep the helper import-safe so tests can load it without starting a session.

## Tool design rules

- Tools must be read-only.
- Tools must validate paths against CWD + $HOME.
- Tools must reject binary or non-UTF8 reads.
- Tools must enforce size limits (default: 1MB).
- Tool output should be trimmed and structured for command generation only.
- Tool runners should enforce timeouts and output byte limits.

## Config files

- Config: `./config.json`
- Schema: `./config.schema.json`

## Recommended tool catalog

### Core (OS/FS) read-only

- sys_info: `uname -a`, `sw_vers`, `sysctl hw.*`
- disk_usage: `df -h`, `diskutil list`
- process_list: `ps -axo pid,ppid,rss,command,%mem`
- network_ports: `lsof -i -P -n`

### Filesystem (scoped)

- list_files(dir): `ls -la <dir>`
- read_file(path): text-only, UTF-8, size <= 1MB
- search_text(pattern, path): `rg` allowlist, scoped

### Dev/Ops (opt-in, read-only)

- git_status: `git status -sb`
- git_branch: `git rev-parse --abbrev-ref HEAD`
- docker_ps: `docker ps`
- kubectl_get(resource, ns): `kubectl get <resource> -n <ns>`
- aws_identity: `aws sts get-caller-identity`

## Define tool examples

### list_files
```js
defineTool("list_files", {
  description: "List files in a directory (CWD + HOME only).",
  parameters: {
    type: "object",
    properties: { dir: { type: "string" } },
    required: ["dir"],
    additionalProperties: false,
  },
  handler: async ({ dir }) => runCommand("ls", ["-la", dir]),
});
```

### read_file
```js
defineTool("read_file", {
  description: "Read a text file (UTF-8, <= 1MB).",
  parameters: {
    type: "object",
    properties: { path: { type: "string" } },
    required: ["path"],
    additionalProperties: false,
  },
  handler: async ({ path }) => readTextFileSafe(path, { maxBytes: 1_000_000 }),
});
```

### search_text
```js
defineTool("search_text", {
  description: "Search text with ripgrep (scoped).",
  parameters: {
    type: "object",
    properties: {
      pattern: { type: "string" },
      path: { type: "string" },
    },
    required: ["pattern", "path"],
    additionalProperties: false,
  },
  handler: async ({ pattern, path }) => runCommand("rg", [pattern, path]),
});
```

## Hooks: deny by default
```js
hooks: {
  onPreToolUse: async ({ toolName }) => {
    if (!ALLOWLIST.has(toolName)) {
      return { permissionDecision: "deny", additionalContext: "Tool denied" };
    }
    return { permissionDecision: "allow" };
  },
}
```

## System message safety

- Append mode recommended.
- If you replace, re-add:
  - Command-only output rules
  - Safety policy text
  - Read-only defaults
  - Tool allowlist with `availableTools`

## Command-only output enforcement

- Reject content with newlines or backticks.
- Strip "command:" prefix if present.
- Fail closed on invalid output.
- Note: "one command" means one shell line. Pipes (`|`), logical operators (`&&`, `||`, `;`), and redirects (`>`, `>>`) are all valid within a single line.

## Defaults

- Tools are only for the Copilot path.
- Patch the SDK import path after `npm ci` until the `vscode-jsonrpc/node` issue is fully fixed upstream.

## Initial tests (manual)

1. Tool allowlist: call a non-allowlisted tool → denied.
2. Path scope: `read_file /etc/hosts` → rejected.
3. Size limit: `read_file` > 1MB → rejected.
4. Search: `search_text` finds matches in CWD.
5. Dev/ops tool: `docker_ps` or `kubectl_get` or `aws_identity` returns read-only info.
6. Config: edit `config.json` then restart shell, verify allowlist changes apply.
7. Model override: set `COPILOT_ZLE_MODEL`, restart shell, verify helper selects it.
8. Regression tests: run `node ./copilot-helper.test.mjs`.

## References

- Policy: `./policy.txt`
- Copilot helper: `./copilot-helper.mjs`
- Helper tests: `./copilot-helper.test.mjs`
- SDK patch: `./patch-copilot-sdk.mjs`
- Tools: `./tools/index.mjs`
- Config: `./config.json`
- Schema: `./config.schema.json`
