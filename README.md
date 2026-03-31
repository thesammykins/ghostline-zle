```text
░░▒▒▓▓  ghostline-zle  ▓▓▒▒░░
            >_
```

# ghostline-zle

`ghostline-zle` is a Ghostty-first `zsh` integration that turns natural language into a single raw shell command.

It is not a chat interface. It fills your command buffer with one command for you to review and run.

The project still keeps `copilot-zle` compatibility names for older installs, but new setup should use `ghostline-zle.zsh`.

## Quick start

Recommended for Ghostty users:

```sh
./scripts/install.sh --write-zshrc
exec zsh
```

That flow:

- checks for `node`, `npm`, and `jq`
- runs `npm ci`
- applies the Copilot SDK patch from `scripts/patch-copilot-sdk.mjs`
- appends a Ghostty-only source block to your `~/.zshrc`

If you do not want the installer to edit your shell config, run:

```sh
./scripts/install.sh
```

and copy the printed source block into your `~/.zshrc` manually.

## Requirements

- macOS
- `zsh`
- Node.js 20+
- `jq`
- a working GitHub Copilot setup for the underlying SDK

## What gets loaded

- `ghostline-zle.zsh`: public entrypoint for new installs
- `copilot-zle.zsh`: compatibility wrapper for older installs
- `shell/copilot-zle-core.zsh`: internal shell core
- `lib/`: Node runtime, daemon, prompt logic, and project context
- `tools/`: optional allowlisted read-only tools
- `config.json`: shipped runtime defaults
- `policy.txt`: prompt policy and command templates

## Manual setup

If you prefer to wire it in yourself, add this to your `~/.zshrc`:

```zsh
if [[ -n "${GHOSTTY_RESOURCES_DIR:-}" || "${TERM_PROGRAM:-}" == "ghostty" ]]; then
  source /absolute/path/to/ghostline-zle/ghostline-zle.zsh
fi
```

Then reload your shell:

```sh
exec zsh
```

If you want to use the plugin outside Ghostty too, source `ghostline-zle.zsh` without the guard.

## Key bindings

- `Ctrl+G`: generate, retry, or apply fix mode
- `Ctrl+E`: explain the current command
- `Alt+H`: open the help menu
- `Ctrl+X H`: open the help menu without Meta-key delay
- `Ctrl+X ]` / `Ctrl+X [`: cycle AI command candidates
- `Right Arrow` or `Ctrl+F`: accept a full ghost suggestion
- `Ctrl+Right`: accept one ghost-text word
- `Esc+Enter`: bypass NL detection and execute the shell command directly

## Modes

- **Generate**: turn natural language into a command
- **Fix**: when the buffer is empty after a failed command, generate a corrected command
- **Refine**: modify the previous AI command
- **Chain**: extend the previous AI command with a pipe or next step
- **Suggest**: passive ghost-text next-command suggestions
- **NL detection**: intercept natural language and route it to AI
- **Autofix**: proactively suggest a fix after command failures
- **Explain**: show a one-line explanation for the current buffer command

When a suggestion or autofix flow reacts to a failed command, the status line now shows an explicit failure notice so it is clear why the plugin is preparing a follow-up.

## Default behavior

The shipped config now keeps the more aggressive features opt-in:

- `suggest.enabled = false`
- `nlDetection.enabled = false`
- `autofix.enabled = false`

You can turn them on from the help menu or by editing `config.json`.

This keeps the default install predictable and avoids false positives from natural-language interception.

## Configuration

The main config file is `./config.json`.

You can point the plugin at another config with:

```sh
export COPILOT_ZLE_CONFIG_FILE=/absolute/path/to/config.json
```

Useful sections:

- `model`
- `tools`
- `limits`
- `context`
- `ui`
- `daemon`
- `suggest`
- `nlDetection`
- `autofix`
- `flightLog`
- `branding`

Important overrides:

- `COPILOT_ZLE_MODEL`
- `COPILOT_ZLE_CONFIG_FILE`
- `COPILOT_ZLE_TOOLS_ALLOWLIST`
- `COPILOT_ZLE_TOOLS_DEVOPS`
- `COPILOT_ZLE_TOOL_MAX_OUTPUT_BYTES`
- `COPILOT_ZLE_TOOL_MAX_FILE_BYTES`
- `COPILOT_ZLE_TOOL_TIMEOUT_MS`
- `COPILOT_ZLE_DEBUG`
- `COPILOT_ZLE_DEBUG_LOG`
- `COPILOT_ZLE_DATA_DIR`
- `COPILOT_ZLE_TEMPLATES_FILE`

## Repository layout

The root is now intentionally small:

- root wrappers and user-facing files stay at the top level
- `shell/` holds shell-only internals
- `lib/` holds the Node runtime
- `scripts/` holds install and patch scripts
- `tests/` holds test runners and regression checks
- `docs/` holds developer-facing reference material

If you are looking for the implementation entrypoints:

- shell core: `shell/copilot-zle-core.zsh`
- helper: `lib/copilot-helper.mjs`
- daemon: `lib/copilot-daemon.mjs`
- prompt service: `lib/copilot-service.mjs`

## Tooling model

Tools are deny-by-default.

Only explicitly allowlisted tools are added to the Copilot session, and Dev/Ops tools stay behind a separate opt-in. This keeps the default behavior command-only and lowers the risk surface.

For developer notes on tool extensibility, see `docs/tool-extensibility.md`.

## Troubleshooting

If setup fails:

- rerun `./scripts/install.sh`
- confirm `node -v` is 20 or newer
- confirm `jq` is installed
- confirm GitHub Copilot auth is working for the underlying SDK

If Ghostty is open and the widget is not available:

- run `exec zsh`
- confirm your `~/.zshrc` contains the Ghostty source block
- confirm the repo path in the source block is still correct

If NL detection is too eager after you enable it:

- keep `nlDetection.enabled` off by default
- use `Esc+Enter` to force shell execution
- note that commands with leading env assignments such as `MOTD_FORCE=1 bash "scripts/motd.sh"` are now treated as shell commands, not prose

## Development

Run the full checks with:

```sh
npm run check
```

The current test suite covers helper logic, project context, NL-detection heuristics, installer behavior, and shell syntax checks.

Useful direct commands:

```sh
node ./tests/copilot-helper.test.mjs
node ./tests/flight-log.test.mjs
node ./tests/project-context.test.mjs
zsh ./tests/nl-detection.test.zsh
zsh ./tests/failure-indicator.test.zsh
node ./tests/install-script.test.mjs
zsh -n ./copilot-zle.zsh
zsh -n ./ghostline-zle.zsh
zsh -n ./shell/copilot-zle-core.zsh
```
