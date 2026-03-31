# AGENTS.md - Copilot ZLE Plugin

## Role

This plugin turns natural language into a single, raw zsh command line. It is not a chat agent.

## Non-negotiables

- Output must be exactly one shell line. Pipes, redirects, and logical operators (`&&`, `||`, `;`) are allowed within that line. Multi-line output (backslash continuations, heredocs) is forbidden. No markdown. No explanations.
- Tools are disabled by default. Only enable with an explicit allowlist.
- Safety policy in `policy.txt` is required input to the system prompt.
- Model default: `gpt-5-mini`.
- Do not add destructive commands unless the user explicitly requests them.
- Prefer graceful signals (SIGTERM) over forceful ones (SIGKILL) by default.

## Environment-aware command generation

The model must reason about the user's actual environment before generating a command. The system prompt includes live context:

- **PWD**: Current working directory (changes per request, not daemon startup dir).
- **OS + Arch**: `darwin (arm64)` etc. — do not emit Linux-only flags on macOS.
- **Shell**: Always `zsh`. Use zsh idioms, not bash-only syntax.
- **TERM_PROGRAM**: The terminal emulator (e.g., `Ghostty`).
- **HOME / DOTFILES**: Canonical paths. Never hardcode `/Users/<name>`.
- **In git repo**: Whether PWD is inside a git worktree.
- **Git summary**: Branch + dirty state. Use for context, not assumptions.
- **Recent history**: Last N commands. Infer workflow context from these.
- **Aliases**: Active shell aliases. Prefer `command <util>` to bypass alias side-effects when clarity matters.
- **Stderr + last failure**: In fix mode, the failed command and its stderr output.

Rules:

1. Read the environment block first. Do not guess the OS or shell.
2. Prefer tools the user already has (e.g., `eza` over `ls` if aliased, `rg` over `grep` if in `$commands`).
3. Use macOS-idiomatic flags (e.g., `stat -f%z` not `stat -c%s`, `pbcopy` not `xclip`).
4. When the user says "here" or "this directory", use the provided PWD — do not default to `$HOME`.
5. In fix mode, read the stderr carefully — fix the actual error, not a guess.

## Tool wiring

- Tool definitions live in `./tools/`.
- Primary config: `./config.json`.
- Model quick config: `config.json` → `model.default`, or override with `COPILOT_ZLE_MODEL`.
- Env overrides: `COPILOT_ZLE_TOOLS_ALLOWLIST`, `COPILOT_ZLE_TOOLS_DEVOPS`.
- Optional override path: `COPILOT_ZLE_CONFIG_FILE`.
- SDK patch hook: `./scripts/patch-copilot-sdk.mjs`.

## Tooling rules

- Use `defineTool` + `createSession({ tools: [...] })` allowlist.
- Keep `hooks.onPreToolUse` deny-by-default for non-allowlisted tools.
- Keep `systemMessage` in append mode unless you re-implement all guardrails.
- Enforce single-line output client-side (reject newlines, backticks, prose).
- Keep the helper safe to import in tests; do not auto-run on module import.
- Tool config lives in `./config.json`; tool definitions live in `./tools/`.

## Modes

- **Generate**: Default. Translate natural language into a shell command.
- **Fix**: Auto-triggered when buffer is empty and last command exited non-zero. Sends failed command + exit code + stderr for correction.
- **Refine**: Triggered when buffer starts with refinement phrases and prior AI command exists. Sends prior command as context for iteration.
- **Chain**: Triggered when buffer starts with "pipe", "then", "now pipe", etc. Extends the prior command with a pipe or step instead of replacing it.
- **Suggest**: Passive next-command ghost-text prediction after command completion. Opt-in via config. Enriched with project context and flight log follow-ups.
- **NL Detect**: Auto-detect natural language input and route to AI. Opt-in via config.
- **Autofix**: Proactive fix suggestions after command failures. Opt-in via config.
- **Explain**: `Ctrl+E` with a command in the buffer. Returns a one-line explanation via status bar. Buffer untouched.

## Anti-patterns

- Enabling tools without a scoped allowlist.
- Expanding path scope beyond `CWD` + `$HOME` without explicit docs and tests.
- Replacing system prompt without including `policy.txt` and output rules.
- Returning text, markdown, multi-line output, or multiple commands on separate lines.
- Using `kill -9` / SIGKILL in examples without explicit user request.
- Redirecting stderr globally in interactive shells (use tempfile approach instead).
- Using daemon `process.env` as environment source — always read `cwd`, `home`, `shell`, `termProgram`, `inGitRepo` from the request payload. The daemon's own environment is stale.
- Emitting Linux-only flags on macOS (e.g., `stat -c`, `xclip`, `--color=always` on BSD tools).
- Ignoring recent history — the user's last commands provide critical workflow context.

## Daemon

- TCP daemon (`lib/copilot-daemon.mjs --tcp`) eliminates cold-start latency.
- State file: `/tmp/copilot-zle-daemon-${UID}.json` (port + PID).
- Idle timeout: configurable, default 5 minutes. Daemon auto-exits.
- Widget tries daemon first, falls back to subprocess.
- Supports `format: "zle"` for structured-line response format.

## Ghost-text suggestions

- Passive next-command predictions via `POSTDISPLAY`.
- Accept full: `→` or `Ctrl+F`. Accept word: `Ctrl+→`.
- Rate-limited, debounced, skip trivial commands.
- Requires daemon. Default off (`suggest.enabled: false`).

## NL auto-detection

- Pure-ZSH heuristic: `$commands`/`$aliases`/`$functions` lookup + word count.
- Leading env assignments are treated as shell commands so valid input such as `MOTD_FORCE=1 bash "scripts/motd.sh"` is not routed into AI generation.
- Intercepts `accept-line`. `Esc+Enter` bypasses to force shell execution.
- Default off (`nlDetection.enabled: false`).

## Candidate cycling

- `Alt+]` / `Alt+[` cycle through AI command candidates.
- Shows `[N/M]` indicator in status line.

## Flight recorder

- Records every AI generation to `~/.local/share/copilot-zle/flight-log.jsonl`.
- Tracks: prompt, command, mode, cwd, execution status, exit code.
- `preexec`/`precmd` hooks detect when AI commands are actually executed.
- Relevant past successes injected as few-shot examples in system prompt.
- Capped at 1000 entries (configurable). Rotates oldest.
- Config: `flightLog.enabled`, `flightLog.maxEntries`, `flightLog.fewShotCount`.

## Project context

- Auto-detects project type from CWD: `package.json` scripts, `Makefile`/`Justfile` targets, `Cargo.toml`, `pyproject.toml`, `go.mod`, Docker, toolchain (mise/direnv/nvm).
- Appends a `PROJECT` block to the system prompt.
- Cached per-CWD per session (zero repeat I/O).
- Config: `context.includeProjectInfo`.

## User templates

- Optional file: `~/.config/copilot-zle/templates.txt`.
- Format: same as `policy.txt` — description→command pairs.
- Appended to system prompt after policy, so user patterns take precedence.
- Env override: `COPILOT_ZLE_TEMPLATES_FILE`.

## Explain mode

- `Ctrl+E` with a command in the buffer.
- Sends to model with explain-only system prompt.
- Result shown via `zle -M` status bar. Buffer untouched.
- Requires daemon.

## Dry validation

- After AI generates a command, checks if the primary binary exists.
- If not found: `[WARN: 'binary' NOT FOUND]` appended to status message.
- Advisory only — command still placed in buffer.
- Handles `command <util>` prefix and env assignments.

## Debugging

- Set `COPILOT_ZLE_DEBUG=1` to log to `/tmp/copilot-zle-debug.log`.
- Run `node ./tests/copilot-helper.test.mjs` for helper-level regression checks.

## What the model sees (vs. this file)

This file is developer guidance for humans and agents editing the plugin code. It is **not** loaded into the Copilot model's context.

The model's behavior is governed by two files:

1. **`lib/copilot-service.mjs` → `systemPrompt()`**: The hardcoded system prompt with environment block, rules, and examples. This is where tool preferences (fd over find, rg over grep, etc.) and macOS-specific guidance live.
2. **`policy.txt`**: Safety policy and command templates. Appended to the system prompt.

If the model generates bad commands (wrong OS flags, ignoring installed tools, wrong directory), fix the system prompt in `lib/copilot-service.mjs` and/or the templates in `policy.txt` — not this file.

## Known gotchas

- `@github/copilot-sdk` on Node 24/25 still needs the `vscode-jsonrpc/node` import patched to `node.js`.
- Preserve the post-install patch flow in `scripts/patch-copilot-sdk.mjs` unless upstream fully resolves it.

## References

- Policy: `./policy.txt`
- Copilot helper: `./lib/copilot-helper.mjs`
- Helper tests: `./tests/copilot-helper.test.mjs`
- SDK patch: `./scripts/patch-copilot-sdk.mjs`
- Tools: `./tools/index.mjs`
- Config: `./config.json`
- Schema: `./config.schema.json`
- Flight log: `./lib/flight-log.mjs`
- Project context: `./lib/project-context.mjs`
- User templates: `~/.config/copilot-zle/templates.txt`
