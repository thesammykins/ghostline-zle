```text
░░▒▒▓▓  ghostline-zle  ▓▓▒▒░░
            >_
```

# ghostline-zle

`ghostline-zle` is the public-facing brand for this ZSH widget, which turns natural language into a single raw shell command without leaving the prompt.

The repository and some internal identifiers still use `copilot-zle` for compatibility while the user-facing branding shifts toward `ghostline-zle`.

It is designed for command generation, not chat. The model sees your current directory, shell, terminal, recent history, git state, aliases, and failed-command stderr so it can produce environment-aware one-liners for macOS `zsh`.

## What it does

- Generates one shell command line from natural language.
- Supports fix, refine, and chain workflows so you can iterate on a command in-place.
- Can show passive next-command suggestions as ghost text.
- Can explain the current command in the status bar.
- Can open an interactive help menu with shortcuts and quick config actions.
- Keeps tool use disabled by default unless you explicitly allowlist tools.
- Records successful generations in a local flight log to improve future suggestions.

## Core behavior

- Output is always a single shell line.
- Tools are deny-by-default.
- Safety policy comes from `policy.txt`.
- The default model is `gpt-5-mini`.
- The plugin prefers safe, non-destructive commands unless you explicitly ask otherwise.

## Modes

- **Generate**: turn natural language into a command.
- **Fix**: when the buffer is empty after a failed command, generate a corrected command.
- **Refine**: modify the previous AI command.
- **Chain**: extend the previous AI command with a pipe or next step.
- **Suggest**: passive ghost-text next-command suggestions.
- **NL detection**: route natural language input to AI automatically.
- **Autofix**: proactively suggest a fix after a failed command.
- **Explain**: show a one-line explanation for the current command.

## Requirements

- macOS
- `zsh`
- Node.js 20+
- `jq`
- A working GitHub Copilot setup for the underlying SDK

## Repository layout

- `ghostline-zle.zsh`: public-facing entrypoint
- `copilot-zle.zsh`: ZLE widget and shell integration
- `copilot-helper.mjs`: direct helper entry point
- `copilot-daemon.mjs`: persistent daemon to avoid cold starts
- `copilot-service.mjs`: Copilot SDK session handling and prompts
- `config.json`: runtime config defaults
- `config.schema.json`: config schema
- `policy.txt`: required prompt policy and command templates

## Setup

1. Install dependencies:

```sh
npm ci
```

The post-install patch for the Copilot SDK runs automatically from `package.json`.

2. Source the plugin from your `.zshrc` or plugin manager:

```sh
source /path/to/ghostline-zle/ghostline-zle.zsh
```

The legacy `copilot-zle.zsh` entrypoint is still present for compatibility, but new installs should prefer `ghostline-zle.zsh`.

3. Restart your shell or reload your config:

```sh
exec zsh
```

The widget binds:

- `Ctrl+G` to generate/apply AI command behavior
- `Ctrl+E` to explain the current command
- `Alt+H` to open the help menu
- `Ctrl+X H` to open the help menu without Meta-key delay
- `Ctrl+X ]` and `Ctrl+X [` to cycle command candidates
- `Right Arrow` or `Ctrl+F` to accept a full ghost suggestion
- `Ctrl+Right` to accept one ghost-text word at a time
- `Esc+Enter` to bypass natural-language detection and run the shell command as-is

## Help menu

Press `Alt+H` to open the built-in help menu.

If your terminal makes `Alt`/`Option` combinations feel delayed, use `Ctrl+X` then `H` instead.

The help menu shows:

- active shortcuts
- the current config file path
- quick actions for viewing `README.md` and `policy.txt`
- quick toggles for `suggest.enabled`
- quick toggles for `nlDetection.enabled`
- quick toggles for `autofix.enabled`
- quick toggles for `daemon.enabled`

If you want deeper customization, use the `c` action in the help menu to open the config file in `$VISUAL`, `$EDITOR`, or `vi`.

## Configuration

The default config lives in `./config.json`.

You can point the plugin at a different file with:

```sh
export COPILOT_ZLE_CONFIG_FILE=/absolute/path/to/config.json
```

### Main config sections

- `model`: default model selection
- `tools`: allowlisted tools and devops toggle
- `limits`: output, file, and timeout limits
- `context`: recent history, git summary, failure context, and project info
- `ui`: AI buffer highlighting
- `daemon`: background daemon behavior
- `suggest`: passive ghost-text suggestions
- `nlDetection`: natural language interception
- `autofix`: failed-command fix suggestions
- `flightLog`: local history used for pattern memory
- `branding`: user-facing labels and wording

### Branding

The first public-release branding surface is intentionally user-facing only. Internal package names, env var prefixes, and on-disk paths stay stable for now.

Example:

```json
{
  "branding": {
    "productName": "ghostline-zle",
    "statusPrefix": "[GHOSTLINE]",
    "errorPrefix": "[GHOSTLINE ERROR]",
    "fixPrefix": "[GHOSTLINE FIX]",
    "explainPrefix": "[GHOSTLINE HELP]",
    "thinkingLabel": "WHISPERING"
  }
}
```

This changes the status-bar labels and spinner wording without forcing a full internal rename. You can still swap in another theme such as MCRN-flavored wording later.

### Selected environment overrides

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

## Tooling model

Tools live in `./tools/`, but the session is created with an explicit allowlist. Non-allowlisted tools are denied before execution. This keeps the default experience command-only and minimizes risk.

## Notes for sharing

- The public-facing entrypoint is `ghostline-zle.zsh`.
- The npm package metadata now uses the `ghostline-zle` name.
- Internal compatibility names such as `copilot-zle.zsh` and `COPILOT_ZLE_*` env vars still remain in place.
- User-facing branding defaults to `ghostline-zle` and can still be changed through config.

## Development and verification

Run the existing checks directly:

```sh
npm run check
```

Or run them individually:

```sh
node ./copilot-helper.test.mjs
node ./flight-log.test.mjs
node ./project-context.test.mjs
zsh -n ./copilot-zle.zsh
zsh -n ./ghostline-zle.zsh
```
