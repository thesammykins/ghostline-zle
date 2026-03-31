# Tool extensibility notes

This file is developer documentation for Ghostline's optional tool support.

It is intentionally **not** a `SKILL.md` file at the repo root. The previous layout was misleading because this project is a shell integration plugin, not a packaged Copilot skill.

## Purpose

Ghostline can expose a small set of read-only tools to the Copilot runtime, but the core contract does not change:

- output must be exactly one shell line
- tools are deny-by-default
- tool scope stays limited to safe, read-only use cases unless explicitly widened

## Current wiring

- runtime config: `./config.json`
- config loader: `./lib/config.mjs`
- shell core: `./shell/copilot-zle-core.zsh`
- Copilot helper: `./lib/copilot-helper.mjs`
- Copilot service: `./lib/copilot-service.mjs`
- tool definitions: `./tools/`
- SDK patch hook: `./scripts/patch-copilot-sdk.mjs`

## Baseline rules

- keep tool use opt-in through an explicit allowlist
- keep Dev/Ops tools behind their separate opt-in
- keep path scope constrained to `CWD` + `$HOME`
- keep the helper import-safe for tests
- keep the runtime command-only even when tools are enabled

## Safe extension pattern

1. Define tools with `defineTool`.
2. Pass only the allowlisted tools into `createSession({ tools: [...] })`.
3. Deny non-allowlisted tool calls in `hooks.onPreToolUse`.
4. Keep output enforcement on the client side so multiline or prose responses are rejected.
5. Prefer config-driven behavior before adding more environment variables.

## Tool design rules

- tools should be read-only by default
- tools should validate paths against `CWD` + `$HOME`
- tools should reject binary or oversized file reads
- tool output should stay small and structured for command generation
- tool runners should enforce timeouts and output byte limits

## Suggested checks

- non-allowlisted tool calls are denied
- out-of-scope file paths are rejected
- size limits are enforced
- allowlisted search/file tools return useful scoped data
- `npm run check` still passes after tool changes

## References

- config: `./config.json`
- schema: `./config.schema.json`
- helper: `./lib/copilot-helper.mjs`
- service: `./lib/copilot-service.mjs`
- patch hook: `./scripts/patch-copilot-sdk.mjs`
- tests: `./tests/`
