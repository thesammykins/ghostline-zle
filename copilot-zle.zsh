# copilot-zle.zsh - AI ZLE Widget for ZSH
# Generates shell commands from natural language without leaving the prompt.
# Engine: Copilot SDK
# Model: gpt-5-mini

# ── Configuration ────────────────────────────────────────────────────
export COPILOT_ZLE_TIMEOUT_MS="${COPILOT_ZLE_TIMEOUT_MS:-30000}"
export COPILOT_ZLE_MODEL="${COPILOT_ZLE_MODEL:-gpt-5-mini}"
export COPILOT_ZLE_PLUGIN_PATH="${COPILOT_ZLE_PLUGIN_PATH:-${(%):-%x}}"
export COPILOT_ZLE_DEBUG_LOG="${COPILOT_ZLE_DEBUG_LOG:-/tmp/copilot-zle-debug.log}"

# ── State Variables (SAM-39/40/41/42/45) ─────────────────────────────
typeset -g  _COPILOT_ZLE_LAST_AI_QUERY=""
typeset -g  _COPILOT_ZLE_LAST_AI_PROMPT=""
typeset -g  _COPILOT_ZLE_LAST_AI_COMMAND=""
typeset -g  _COPILOT_ZLE_LAST_EXECUTED_COMMAND=""
typeset -g  _COPILOT_ZLE_LAST_EXIT_CODE="0"
typeset -g  _COPILOT_ZLE_GENERATED_BUFFER=""
# Async state (SAM-45)
typeset -gi _COPILOT_ZLE_ASYNC_ACTIVE=0
typeset -g  _COPILOT_ZLE_ASYNC_MODE=""
typeset -g  _COPILOT_ZLE_RESULT_FD=""
typeset -g  _COPILOT_ZLE_SPINNER_FD=""
# Pending result (written by zle -F handler, consumed by apply widget)
typeset -g  _COPILOT_ZLE_PENDING_CMD=""
typeset -g  _COPILOT_ZLE_PENDING_EC=""
typeset -g  _COPILOT_ZLE_PENDING_ERR=""
# Cached UI config (read once at load, avoids forking jq inside zle -F handlers)
typeset -g  _COPILOT_ZLE_CFG_HIGHLIGHT_ENABLED=""
typeset -g  _COPILOT_ZLE_CFG_HIGHLIGHT_STYLE=""
typeset -gi _COPILOT_ZLE_SPINNER_IDX=0
typeset -ga _COPILOT_ZLE_SPINNER_FRAMES=()
# Daemon state
typeset -gi _COPILOT_ZLE_DAEMON_PORT=0
typeset -gi _COPILOT_ZLE_DAEMON_PID=0
typeset -gi _COPILOT_ZLE_USING_DAEMON=0
typeset -g  _COPILOT_ZLE_CFG_DAEMON_ENABLED=""
# Ghost-text suggest state
typeset -g  _COPILOT_ZLE_GHOST_TEXT=""
typeset -g  _COPILOT_ZLE_GHOST_FD=""
typeset -gi _COPILOT_ZLE_LAST_SUGGEST_TS=0
typeset -g  _COPILOT_ZLE_CFG_SUGGEST_ENABLED=""
typeset -g  _COPILOT_ZLE_CFG_SUGGEST_GHOST_STYLE=""
typeset -g  _COPILOT_ZLE_CFG_SUGGEST_RATE_LIMIT_MS=""
typeset -g  _COPILOT_ZLE_CFG_SUGGEST_SKIP_CMDS=""
# NL detection state
typeset -g  _COPILOT_ZLE_CFG_NL_ENABLED=""
typeset -g  _COPILOT_ZLE_CFG_NL_MIN_WORDS=""
typeset -g  _COPILOT_ZLE_CFG_NL_INDICATOR=""
# Autofix state
typeset -g  _COPILOT_ZLE_CFG_AUTOFIX_ENABLED=""
typeset -g  _COPILOT_ZLE_CFG_AUTOFIX_MODE=""
typeset -g  _COPILOT_ZLE_CFG_BRAND_PRODUCT_NAME=""
typeset -g  _COPILOT_ZLE_CFG_BRAND_STATUS_PREFIX=""
typeset -g  _COPILOT_ZLE_CFG_BRAND_ERROR_PREFIX=""
typeset -g  _COPILOT_ZLE_CFG_BRAND_FIX_PREFIX=""
typeset -g  _COPILOT_ZLE_CFG_BRAND_EXPLAIN_PREFIX=""
typeset -g  _COPILOT_ZLE_CFG_BRAND_THINKING_LABEL=""
# Stderr capture state
typeset -g  _COPILOT_ZLE_LAST_STDERR=""
typeset -g  _COPILOT_ZLE_STDERR_FILE="${COPILOT_ZLE_STDERR_FILE:-/tmp/copilot-zle-stderr-$$.log}"
# Candidate cycling state
typeset -ga _COPILOT_ZLE_CANDIDATES=()
typeset -gi _COPILOT_ZLE_CANDIDATE_IDX=0
# Flight log tracking
typeset -g  _COPILOT_ZLE_TRACKING_EXECUTION=""

# ── Hooks: track last command, exit code, and stderr (SAM-40) ────────
autoload -Uz add-zsh-hook

_copilot_zle_preexec() {
  _COPILOT_ZLE_LAST_EXECUTED_COMMAND="$1"
  # Track if this was an AI-generated command (for flight log feedback)
  if [[ -n "$_COPILOT_ZLE_LAST_AI_COMMAND" && "$1" == "$_COPILOT_ZLE_LAST_AI_COMMAND" ]]; then
    typeset -g _COPILOT_ZLE_TRACKING_EXECUTION="$1"
  else
    typeset -g _COPILOT_ZLE_TRACKING_EXECUTION=""
  fi
  # Reset stderr capture file for next command
  if [[ -n "$_COPILOT_ZLE_STDERR_FILE" ]]; then
    : > "$_COPILOT_ZLE_STDERR_FILE" 2>/dev/null
  fi
}

_copilot_zle_precmd() {
  _COPILOT_ZLE_LAST_EXIT_CODE="$?"
  # Flight log: mark AI command as executed with exit code
  if [[ -n "$_COPILOT_ZLE_TRACKING_EXECUTION" ]]; then
    _copilot_zle_mark_executed "$_COPILOT_ZLE_TRACKING_EXECUTION" "$_COPILOT_ZLE_LAST_EXIT_CODE" &!
    _COPILOT_ZLE_TRACKING_EXECUTION=""
  fi
  # Read captured stderr (populated by wrapper, if enabled)
  if [[ -s "$_COPILOT_ZLE_STDERR_FILE" ]]; then
    _COPILOT_ZLE_LAST_STDERR="$(tail -50 "$_COPILOT_ZLE_STDERR_FILE" 2>/dev/null)"
  else
    _COPILOT_ZLE_LAST_STDERR=""
  fi
}

add-zsh-hook preexec _copilot_zle_preexec
add-zsh-hook precmd  _copilot_zle_precmd

# ── Highlight + ghost-text clear hook ─────────────────────────────────
if autoload -Uz add-zle-hook-widget 2>/dev/null; then
  add-zle-hook-widget line-pre-redraw _copilot_zle_ghost_line_changed 2>/dev/null || true
fi

# ── Config Reader (SAM-44) ───────────────────────────────────────────
typeset -g _COPILOT_ZLE_CONFIG_CACHE=""
typeset -g _COPILOT_ZLE_CONFIG_PATH=""

_copilot_zle_read_config() {
  local key="$1" default="$2"
  if [[ -z "$_COPILOT_ZLE_CONFIG_PATH" ]]; then
    local dir
    dir="$(_copilot_zle_helpers_dir)"
    _COPILOT_ZLE_CONFIG_PATH="${COPILOT_ZLE_CONFIG_FILE:-$dir/config.json}"
  fi
  if [[ ! -f "$_COPILOT_ZLE_CONFIG_PATH" ]]; then
    echo "$default"
    return
  fi
  local val
  val="$(jq -r "$key // empty" "$_COPILOT_ZLE_CONFIG_PATH" 2>/dev/null)"
  if [[ -n "$val" ]]; then
    echo "$val"
  else
    echo "$default"
  fi
}

# ── Internals ────────────────────────────────────────────────────────
_copilot_zle_helpers_dir() {
  local script_path
  script_path="$COPILOT_ZLE_PLUGIN_PATH"
  if [[ -z "$script_path" ]]; then
    script_path="${(%):-%x}"
  fi
  if [[ -z "$script_path" ]]; then
    script_path="$0"
  fi
  echo "${script_path:A:h}"
}

_copilot_zle_debug_log() {
  if [[ -n "${COPILOT_ZLE_DEBUG:-}" ]]; then
    printf '%s\n' "$1" >> "$COPILOT_ZLE_DEBUG_LOG"
  fi
}

_copilot_zle_show_message() {
  local prefix="$1" body="$2"
  if [[ -n "$body" ]]; then
    zle -M "$prefix $body"
  else
    zle -M "$prefix"
  fi
}

_copilot_zle_status_message() {
  _copilot_zle_show_message "$_COPILOT_ZLE_CFG_BRAND_STATUS_PREFIX" "$1"
}

_copilot_zle_error_message() {
  _copilot_zle_show_message "$_COPILOT_ZLE_CFG_BRAND_ERROR_PREFIX" "$1"
}

_copilot_zle_fix_message() {
  _copilot_zle_show_message "$_COPILOT_ZLE_CFG_BRAND_FIX_PREFIX" "$1"
}

_copilot_zle_explain_message() {
  _copilot_zle_show_message "$_COPILOT_ZLE_CFG_BRAND_EXPLAIN_PREFIX" "$1"
}

_copilot_zle_reload_cached_config() {
  _COPILOT_ZLE_CFG_HIGHLIGHT_ENABLED="$(_copilot_zle_read_config '.ui.highlightAiBuffer' 'true')"
  _COPILOT_ZLE_CFG_HIGHLIGHT_STYLE="$(_copilot_zle_read_config '.ui.highlightStyle' 'underline')"
  _COPILOT_ZLE_CFG_DAEMON_ENABLED="$(_copilot_zle_read_config '.daemon.enabled' 'true')"
  _COPILOT_ZLE_CFG_SUGGEST_ENABLED="$(_copilot_zle_read_config '.suggest.enabled' 'false')"
  _COPILOT_ZLE_CFG_SUGGEST_GHOST_STYLE="$(_copilot_zle_read_config '.suggest.ghostStyle' 'fg=240')"
  _COPILOT_ZLE_CFG_SUGGEST_RATE_LIMIT_MS="$(_copilot_zle_read_config '.suggest.rateLimitMs' '2000')"
  _COPILOT_ZLE_CFG_SUGGEST_SKIP_CMDS="$(_copilot_zle_read_config '.suggest.skipCommands | join(",")' 'cd,ls,clear,pwd,exit,true,false')"
  _COPILOT_ZLE_CFG_NL_ENABLED="$(_copilot_zle_read_config '.nlDetection.enabled' 'false')"
  _COPILOT_ZLE_CFG_NL_MIN_WORDS="$(_copilot_zle_read_config '.nlDetection.minWords' '3')"
  _COPILOT_ZLE_CFG_NL_INDICATOR="$(_copilot_zle_read_config '.nlDetection.indicator' '[NL]')"
  _COPILOT_ZLE_CFG_AUTOFIX_ENABLED="$(_copilot_zle_read_config '.autofix.enabled' 'false')"
  _COPILOT_ZLE_CFG_AUTOFIX_MODE="$(_copilot_zle_read_config '.autofix.displayMode' 'banner')"
  _COPILOT_ZLE_CFG_BRAND_PRODUCT_NAME="$(_copilot_zle_read_config '.branding.productName' 'ghostline-zle')"
  _COPILOT_ZLE_CFG_BRAND_STATUS_PREFIX="$(_copilot_zle_read_config '.branding.statusPrefix' '[GHOSTLINE]')"
  _COPILOT_ZLE_CFG_BRAND_ERROR_PREFIX="$(_copilot_zle_read_config '.branding.errorPrefix' '[GHOSTLINE ERROR]')"
  _COPILOT_ZLE_CFG_BRAND_FIX_PREFIX="$(_copilot_zle_read_config '.branding.fixPrefix' '[GHOSTLINE FIX]')"
  _COPILOT_ZLE_CFG_BRAND_EXPLAIN_PREFIX="$(_copilot_zle_read_config '.branding.explainPrefix' '[GHOSTLINE HELP]')"
  _COPILOT_ZLE_CFG_BRAND_THINKING_LABEL="$(_copilot_zle_read_config '.branding.thinkingLabel' 'WHISPERING')"
  _COPILOT_ZLE_SPINNER_FRAMES=(
    "${_COPILOT_ZLE_CFG_BRAND_THINKING_LABEL}."
    "${_COPILOT_ZLE_CFG_BRAND_THINKING_LABEL}.."
    "${_COPILOT_ZLE_CFG_BRAND_THINKING_LABEL}..."
    "${_COPILOT_ZLE_CFG_BRAND_THINKING_LABEL}...."
  )
}

# Cache UI config at load time (safe to fork jq here, outside ZLE context)
_copilot_zle_reload_cached_config

_copilot_zle_open_with_editor() {
  local target="$1" label="$2"
  [[ -n "$target" ]] || return 1

  local -a editor_cmd
  editor_cmd=( ${(z)${VISUAL:-${EDITOR:-vi}}} )
  (( ${#editor_cmd[@]} > 0 )) || editor_cmd=(vi)

  zle -I
  print -r -- ""
  print -r -- "opening ${label} with ${editor_cmd[1]}..."
  command "${editor_cmd[@]}" "$target"
  zle reset-prompt
  zle -R
}

_copilot_zle_open_with_pager() {
  local target="$1" label="$2"
  [[ -f "$target" ]] || {
    _copilot_zle_error_message "${label} not found."
    return 1
  }

  local -a pager_cmd
  if [[ -n "${PAGER:-}" ]]; then
    pager_cmd=( ${(z)${PAGER}} )
  elif [[ -x "$(command -v less)" ]]; then
    pager_cmd=(less -R)
  else
    pager_cmd=(cat)
  fi

  zle -I
  print -r -- ""
  print -r -- "opening ${label}..."
  command "${pager_cmd[@]}" "$target"
  zle reset-prompt
  zle -R
}

_copilot_zle_toggle_config_boolean() {
  local key_path="$1" label="$2"
  local config_path
  config_path="${_COPILOT_ZLE_CONFIG_PATH:-${COPILOT_ZLE_CONFIG_FILE:-$(_copilot_zle_helpers_dir)/config.json}}"

  local new_value
  new_value="$(
    NODE_NO_WARNINGS=1 node -e '
      const fs = require("node:fs");
      const [filePath, dottedPath] = process.argv.slice(1);
      let config = {};
      if (fs.existsSync(filePath)) {
        try {
          const raw = fs.readFileSync(filePath, "utf8").trim();
          if (raw) config = JSON.parse(raw);
        } catch (error) {
          console.error(error.message);
          process.exit(1);
        }
      }
      const parts = dottedPath.split(".");
      let cursor = config;
      for (let index = 0; index < parts.length - 1; index += 1) {
        const part = parts[index];
        if (!cursor[part] || typeof cursor[part] !== "object" || Array.isArray(cursor[part])) {
          cursor[part] = {};
        }
        cursor = cursor[part];
      }
      const last = parts[parts.length - 1];
      cursor[last] = !Boolean(cursor[last]);
      fs.writeFileSync(filePath, JSON.stringify(config, null, 2) + "\n", "utf8");
      process.stdout.write(cursor[last] ? "enabled" : "disabled");
    ' "$config_path" "$key_path" 2>/dev/null
  )"

  if [[ -z "$new_value" ]]; then
    _copilot_zle_error_message "Could not update ${label}."
    return 1
  fi

  _copilot_zle_reload_cached_config
  _copilot_zle_status_message "${label}: ${new_value}. Config saved to ${config_path}"
}

copilot_zle_help() {
  local helpers_dir config_path readme_path policy_path
  helpers_dir="$(_copilot_zle_helpers_dir)"
  config_path="${_COPILOT_ZLE_CONFIG_PATH:-${COPILOT_ZLE_CONFIG_FILE:-$helpers_dir/config.json}}"
  readme_path="$helpers_dir/README.md"
  policy_path="$helpers_dir/policy.txt"

  zle -I
  print -r -- ""
  print -r -- "░░▒▒▓▓  ghostline-zle  ▓▓▒▒░░"
  print -r -- "            >_"
  print -r -- ""
  print -r -- "shortcuts"
  print -r -- "  Ctrl+G        generate / retry / fix mode"
  print -r -- "  Ctrl+E        explain current buffer command"
  print -r -- "  Alt+H         open this help menu"
  print -r -- "  Ctrl+X H      open this help menu without Meta-key delay"
  print -r -- "  Alt+] / Alt+[ cycle AI candidates"
  print -r -- "  Right / Ctrl+F accept full ghost suggestion"
  print -r -- "  Ctrl+Right    accept one ghost word"
  print -r -- "  Esc+Enter     bypass NL detection"
  print -r -- ""
  print -r -- "quick options"
  print -r -- "  s  toggle suggest.enabled      (${_COPILOT_ZLE_CFG_SUGGEST_ENABLED})"
  print -r -- "  n  toggle nlDetection.enabled  (${_COPILOT_ZLE_CFG_NL_ENABLED})"
  print -r -- "  a  toggle autofix.enabled      (${_COPILOT_ZLE_CFG_AUTOFIX_ENABLED})"
  print -r -- "  d  toggle daemon.enabled       (${_COPILOT_ZLE_CFG_DAEMON_ENABLED})"
  print -r -- ""
  print -r -- "files"
  print -r -- "  c  edit config    ${config_path}"
  print -r -- "  r  view README    ${readme_path}"
  print -r -- "  p  view policy    ${policy_path}"
  print -r -- "  q  close"
  print -n -- "choose action: "

  local choice=""
  read -rk 1 choice
  print -r -- ""

  case "$choice" in
    [sS]) _copilot_zle_toggle_config_boolean "suggest.enabled" "suggestions" ;;
    [nN]) _copilot_zle_toggle_config_boolean "nlDetection.enabled" "natural language detection" ;;
    [aA]) _copilot_zle_toggle_config_boolean "autofix.enabled" "autofix" ;;
    [dD]) _copilot_zle_toggle_config_boolean "daemon.enabled" "daemon" ;;
    [cC]) _copilot_zle_open_with_editor "$config_path" "config" ;;
    [rR]) _copilot_zle_open_with_pager "$readme_path" "README" ;;
    [pP]) _copilot_zle_open_with_pager "$policy_path" "policy" ;;
    *) ;;
  esac

  zle reset-prompt
  zle -R
}

# ── Flight Log Execution Tracking ────────────────────────────────────
_copilot_zle_mark_executed() {
  local command="$1" exit_code="$2"
  [[ -n "$command" ]] || return

  # Prefer daemon path (fire-and-forget)
  if _copilot_zle_daemon_is_running 2>/dev/null; then
    zmodload -e zsh/net/tcp || zmodload zsh/net/tcp 2>/dev/null || return
    if (( _COPILOT_ZLE_DAEMON_PORT == 0 )); then
      _copilot_zle_daemon_read_state
    fi
    local escaped_cmd
    escaped_cmd="$(printf '%s' "$command" | jq -Rs '.' 2>/dev/null || echo '""')"
    local request="{\"type\":\"mark_executed\",\"payload\":{\"command\":${escaped_cmd},\"exitCode\":${exit_code:-0}}}"
    {
      ztcp 127.0.0.1 "$_COPILOT_ZLE_DAEMON_PORT" 2>/dev/null && {
        print -r -u "$REPLY" -- "$request"
        ztcp -c "$REPLY" 2>/dev/null
      }
    } 2>/dev/null
  else
    # Fallback: call Node directly (lightweight, fire-and-forget)
    local helpers_dir
    helpers_dir="$(_copilot_zle_helpers_dir)"
    NODE_NO_WARNINGS=1 node -e "
      import { markExecuted } from '${helpers_dir}/flight-log.mjs';
      markExecuted(process.argv[1], parseInt(process.argv[2], 10));
    " "$command" "$exit_code" 2>/dev/null
  fi
}

# ── Daemon Lifecycle ─────────────────────────────────────────────────
_copilot_zle_daemon_state_file() {
  echo "${COPILOT_ZLE_DAEMON_STATE_FILE:-/tmp/copilot-zle-daemon-${UID}.json}"
}

_copilot_zle_daemon_is_running() {
  local state_file
  state_file="$(_copilot_zle_daemon_state_file)"
  [[ -f "$state_file" ]] || return 1

  local pid
  pid="$(jq -r '.pid // empty' "$state_file" 2>/dev/null)"
  [[ -n "$pid" ]] || return 1

  kill -0 "$pid" 2>/dev/null || {
    rm -f "$state_file" 2>/dev/null
    return 1
  }
  return 0
}

_copilot_zle_daemon_read_state() {
  local state_file
  state_file="$(_copilot_zle_daemon_state_file)"
  _COPILOT_ZLE_DAEMON_PORT="$(jq -r '.port // empty' "$state_file" 2>/dev/null)"
  _COPILOT_ZLE_DAEMON_PID="$(jq -r '.pid // empty' "$state_file" 2>/dev/null)"
}

_copilot_zle_daemon_start() {
  local helpers_dir
  helpers_dir="$(_copilot_zle_helpers_dir)"
  local state_file
  state_file="$(_copilot_zle_daemon_state_file)"

  rm -f "$state_file" 2>/dev/null

  local stderr_target="/dev/null"
  if [[ -n "${COPILOT_ZLE_DEBUG:-}" ]]; then
    stderr_target="$COPILOT_ZLE_DEBUG_LOG"
  fi

  NODE_NO_WARNINGS=1 node "$helpers_dir/copilot-daemon.mjs" --tcp \
    2>>"$stderr_target" &!

  local attempts=0
  while (( attempts < 50 )) && [[ ! -f "$state_file" ]]; do
    sleep 0.1
    (( attempts++ ))
  done

  if [[ ! -f "$state_file" ]]; then
    _copilot_zle_debug_log "daemon start failed: state file not created"
    return 1
  fi

  _copilot_zle_daemon_read_state
  _copilot_zle_debug_log "daemon started: pid=$_COPILOT_ZLE_DAEMON_PID port=$_COPILOT_ZLE_DAEMON_PORT"
  return 0
}

_copilot_zle_daemon_ensure() {
  [[ "$_COPILOT_ZLE_CFG_DAEMON_ENABLED" == "true" ]] || return 1

  if _copilot_zle_daemon_is_running; then
    if (( _COPILOT_ZLE_DAEMON_PORT == 0 )); then
      _copilot_zle_daemon_read_state
      _copilot_zle_debug_log "daemon reconnected: pid=$_COPILOT_ZLE_DAEMON_PID port=$_COPILOT_ZLE_DAEMON_PORT"
    fi
    return 0
  fi

  _copilot_zle_debug_log "daemon not running, starting..."
  _copilot_zle_daemon_start
}

# ── Ghost-Text Suggestions ───────────────────────────────────────────
_copilot_zle_ghost_clear() {
  if [[ -n "$_COPILOT_ZLE_GHOST_TEXT" ]]; then
    _COPILOT_ZLE_GHOST_TEXT=""
    POSTDISPLAY=""
    region_highlight=("${(@)region_highlight:#*postdisplay*}")
  fi
}

_copilot_zle_ghost_render() {
  local suggestion="$1"
  if [[ -z "$suggestion" ]]; then
    _copilot_zle_ghost_clear
    return
  fi
  _COPILOT_ZLE_GHOST_TEXT="$suggestion"
  POSTDISPLAY="$suggestion"
  _copilot_zle_debug_log "ghost render: '${suggestion:0:80}'"
}

_copilot_zle_ghost_accept_full() {
  if [[ -z "$_COPILOT_ZLE_GHOST_TEXT" ]]; then
    # No ghost text — pass through to default right-arrow behavior
    zle forward-char
    return
  fi
  _copilot_zle_debug_log "ghost accept full: '${_COPILOT_ZLE_GHOST_TEXT:0:80}'"
  BUFFER="${BUFFER}${_COPILOT_ZLE_GHOST_TEXT}"
  CURSOR=${#BUFFER}
  _copilot_zle_ghost_clear
}

_copilot_zle_ghost_accept_word() {
  if [[ -z "$_COPILOT_ZLE_GHOST_TEXT" ]]; then
    zle forward-word
    return
  fi
  local ghost="$_COPILOT_ZLE_GHOST_TEXT"
  # Extract next word (up to whitespace boundary)
  local word="${ghost%%[[:space:]]*}"
  local rest="${ghost#"$word"}"
  # Include trailing whitespace with the word
  if [[ "$rest" == [[:space:]]* ]]; then
    word="${word}${rest%%[^[:space:]]*}"
    rest="${rest#${rest%%[^[:space:]]*}}"
  fi
  BUFFER="${BUFFER}${word}"
  CURSOR=${#BUFFER}
  if [[ -n "$rest" ]]; then
    _COPILOT_ZLE_GHOST_TEXT="$rest"
    POSTDISPLAY="$rest"
  else
    _copilot_zle_ghost_clear
  fi
}

# Clear ghost text on any buffer change
_copilot_zle_ghost_line_changed() {
  if [[ -n "$_COPILOT_ZLE_GHOST_TEXT" && -n "$BUFFER" ]]; then
    # If user started typing, clear ghost
    _copilot_zle_ghost_clear
  fi
  # Also handle AI highlight clearing
  if [[ -n "$_COPILOT_ZLE_GENERATED_BUFFER" && "$BUFFER" != "$_COPILOT_ZLE_GENERATED_BUFFER" ]]; then
    region_highlight=()
    _COPILOT_ZLE_GENERATED_BUFFER=""
  fi
}

# Suggest result handler (async, lightweight)
_copilot_zle_suggest_result_handler() {
  local fd=$1
  local line=""

  if [[ -z "$2" || "$2" == "hup" ]]; then
    read -r -u $fd line 2>/dev/null
    read -r -u $fd line 2>/dev/null  # skip error line
    local cmd=""
    IFS='' read -rd '' -u $fd cmd 2>/dev/null
    _copilot_zle_debug_log "suggest result: '$cmd'"

    # Only show if buffer is still empty (user hasn't started typing)
    if [[ -z "$BUFFER" && -n "$cmd" ]]; then
      _copilot_zle_ghost_render "$cmd"
      zle -R
    fi
  fi

  if (( _COPILOT_ZLE_USING_DAEMON )); then
    ztcp -c "$fd" 2>/dev/null
  else
    builtin exec {fd}<&- 2>/dev/null
  fi
  zle -F "$fd" 2>/dev/null
  _COPILOT_ZLE_GHOST_FD=""
}

_copilot_zle_request_suggest() {
  [[ "$_COPILOT_ZLE_CFG_SUGGEST_ENABLED" == "true" ]] || return

  # Rate limit
  local now_ms
  now_ms=$(( $(date +%s) * 1000 ))
  local elapsed=$(( now_ms - _COPILOT_ZLE_LAST_SUGGEST_TS ))
  if (( elapsed < _COPILOT_ZLE_CFG_SUGGEST_RATE_LIMIT_MS )); then
    return
  fi
  _COPILOT_ZLE_LAST_SUGGEST_TS=$now_ms

  # Skip trivial commands
  local cmd_name="${_COPILOT_ZLE_LAST_EXECUTED_COMMAND%% *}"
  if [[ ",$_COPILOT_ZLE_CFG_SUGGEST_SKIP_CMDS," == *",$cmd_name,"* ]]; then
    return
  fi

  # Need daemon for suggestions
  _copilot_zle_daemon_ensure 2>/dev/null || return

  zmodload -e zsh/net/tcp || zmodload zsh/net/tcp 2>/dev/null || return

  _copilot_zle_debug_log "suggest: requesting for '$_COPILOT_ZLE_LAST_EXECUTED_COMMAND' (exit $_COPILOT_ZLE_LAST_EXIT_CODE)"

  # Cancel any in-flight suggest
  if [[ -n "$_COPILOT_ZLE_GHOST_FD" ]]; then
    ztcp -c "$_COPILOT_ZLE_GHOST_FD" 2>/dev/null
    zle -F "$_COPILOT_ZLE_GHOST_FD" 2>/dev/null
    _COPILOT_ZLE_GHOST_FD=""
  fi

  ztcp 127.0.0.1 "$_COPILOT_ZLE_DAEMON_PORT" 2>/dev/null || return
  local tcp_fd=$REPLY

  local history_snippet=""
  if whence -w fc >/dev/null 2>&1; then
    history_snippet="$(fc -l -5 2>/dev/null | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//' || echo "")"
  fi

  # JSON-escape the history
  local escaped_history
  escaped_history="$(printf '%s' "$history_snippet" | jq -Rs '.' 2>/dev/null || echo '""')"
  local escaped_cmd
  escaped_cmd="$(printf '%s' "$_COPILOT_ZLE_LAST_EXECUTED_COMMAND" | jq -Rs '.' 2>/dev/null || echo '""')"

  local request="{\"id\":${RANDOM},\"type\":\"suggest\",\"format\":\"zle\",\"payload\":{\"lastCommand\":${escaped_cmd},\"exitCode\":${_COPILOT_ZLE_LAST_EXIT_CODE:-0},\"cwd\":\"${PWD}\",\"home\":\"${HOME}\",\"recentHistory\":${escaped_history}}}"

  print -r -u "$tcp_fd" -- "$request"

  _COPILOT_ZLE_GHOST_FD=$tcp_fd
  _COPILOT_ZLE_USING_DAEMON=1
  zle -F "$tcp_fd" _copilot_zle_suggest_result_handler
}

# Hook into precmd for passive suggestions
_copilot_zle_suggest_precmd() {
  [[ "$_COPILOT_ZLE_CFG_SUGGEST_ENABLED" == "true" ]] || return
  # Only suggest if we actually ran a command (not just pressing Enter)
  [[ -n "$_COPILOT_ZLE_LAST_EXECUTED_COMMAND" ]] || return
  # Schedule suggestion (will be picked up by ZLE event loop)
  # Use sched for debounce, or just request directly
  _copilot_zle_request_suggest 2>/dev/null
}

add-zsh-hook precmd _copilot_zle_suggest_precmd

# Register ghost-text widgets
zle -N _copilot_zle_ghost_accept_full
zle -N _copilot_zle_ghost_accept_word
zle -N _copilot_zle_suggest_result_handler

# ── Natural Language Auto-Detection ──────────────────────────────────
# Pure-ZSH heuristic: if input starts with a word that is NOT a known command
# and contains >= minWords, classify as natural language.
_copilot_zle_is_natural_language() {
  local input="$1"
  [[ -n "$input" ]] || return 1

  # Count words
  local -a words=( ${(z)input} )
  (( ${#words} >= _COPILOT_ZLE_CFG_NL_MIN_WORDS )) || return 1

  local first_word="${words[1]}"

  # Skip if starts with path, variable, or special chars
  case "$first_word" in
    /*|~*|./*|../*|'$'*|'!'*|'#'*) return 1 ;;
  esac

  # Check if first word is a known command, alias, function, or builtin
  if (( $+commands[$first_word] )) || \
     (( $+aliases[$first_word] )) || \
     (( $+functions[$first_word] )) || \
     whence -w "$first_word" >/dev/null 2>&1; then
    return 1
  fi

  return 0
}

# Custom accept-line that intercepts NL input
_copilot_zle_accept_line() {
  if [[ "$_COPILOT_ZLE_CFG_NL_ENABLED" == "true" ]] && \
     _copilot_zle_is_natural_language "$BUFFER"; then
    _copilot_zle_debug_log "NL detected: '$BUFFER'"
    # Route to AI generation instead of shell execution
    copilot_zle_generate
    return
  fi
  # Clear ghost text before executing
  _copilot_zle_ghost_clear
  _copilot_zle_debug_log "accept-line: executing shell command"
  zle .accept-line
}
zle -N accept-line _copilot_zle_accept_line

# Escape key bypasses NL detection (forces shell execution)
_copilot_zle_force_execute() {
  _copilot_zle_ghost_clear
  zle .accept-line
}
zle -N _copilot_zle_force_execute
bindkey '^[^M' _copilot_zle_force_execute 2>/dev/null || true  # Esc+Enter

# ── Candidate Cycling ────────────────────────────────────────────────
_copilot_zle_cycle_next() {
  (( ${#_COPILOT_ZLE_CANDIDATES} > 1 )) || return
  _COPILOT_ZLE_CANDIDATE_IDX=$(( (_COPILOT_ZLE_CANDIDATE_IDX % ${#_COPILOT_ZLE_CANDIDATES}) + 1 ))
  local candidate="${_COPILOT_ZLE_CANDIDATES[$_COPILOT_ZLE_CANDIDATE_IDX]}"
  BUFFER="$candidate"
  CURSOR=${#BUFFER}
  _COPILOT_ZLE_LAST_AI_COMMAND="$candidate"
  _copilot_zle_status_message "CANDIDATE ${_COPILOT_ZLE_CANDIDATE_IDX}/${#_COPILOT_ZLE_CANDIDATES}"
  zle -R
}

_copilot_zle_cycle_prev() {
  (( ${#_COPILOT_ZLE_CANDIDATES} > 1 )) || return
  _COPILOT_ZLE_CANDIDATE_IDX=$(( _COPILOT_ZLE_CANDIDATE_IDX - 1 ))
  (( _COPILOT_ZLE_CANDIDATE_IDX < 1 )) && _COPILOT_ZLE_CANDIDATE_IDX=${#_COPILOT_ZLE_CANDIDATES}
  local candidate="${_COPILOT_ZLE_CANDIDATES[$_COPILOT_ZLE_CANDIDATE_IDX]}"
  BUFFER="$candidate"
  CURSOR=${#BUFFER}
  _COPILOT_ZLE_LAST_AI_COMMAND="$candidate"
  _copilot_zle_status_message "CANDIDATE ${_COPILOT_ZLE_CANDIDATE_IDX}/${#_COPILOT_ZLE_CANDIDATES}"
  zle -R
}

zle -N _copilot_zle_cycle_next
zle -N _copilot_zle_cycle_prev
bindkey '^[]' _copilot_zle_cycle_next 2>/dev/null || true    # Alt+]
bindkey '^[[' _copilot_zle_cycle_prev 2>/dev/null || true    # Alt+[

# ── Proactive Autofix ────────────────────────────────────────────────
_copilot_zle_autofix_precmd() {
  [[ "$_COPILOT_ZLE_CFG_AUTOFIX_ENABLED" == "true" ]] || return
  # Only trigger on non-zero exit
  [[ "$_COPILOT_ZLE_LAST_EXIT_CODE" != "0" ]] || return
  [[ -n "$_COPILOT_ZLE_LAST_EXECUTED_COMMAND" ]] || return

  _copilot_zle_debug_log "autofix: command='$_COPILOT_ZLE_LAST_EXECUTED_COMMAND' exit=$_COPILOT_ZLE_LAST_EXIT_CODE"

  # Need daemon for autofix
  _copilot_zle_daemon_ensure 2>/dev/null || return
  zmodload -e zsh/net/tcp || zmodload zsh/net/tcp 2>/dev/null || return

  ztcp 127.0.0.1 "$_COPILOT_ZLE_DAEMON_PORT" 2>/dev/null || return
  local tcp_fd=$REPLY

  local escaped_cmd
  escaped_cmd="$(printf '%s' "$_COPILOT_ZLE_LAST_EXECUTED_COMMAND" | jq -Rs '.' 2>/dev/null || echo '""')"
  local escaped_stderr
  escaped_stderr="$(printf '%s' "$_COPILOT_ZLE_LAST_STDERR" | jq -Rs '.' 2>/dev/null || echo '""')"

  local payload="{\"prompt\":\"fix the last command that failed\",\"mode\":\"fix\",\"recentHistory\":\"\",\"gitSummary\":\"\",\"lastFailure\":${escaped_cmd},\"lastStderr\":${escaped_stderr},\"priorAi\":{\"prompt\":\"\",\"command\":\"\"}}"
  local request="{\"id\":${RANDOM},\"type\":\"generate\",\"format\":\"zle\",\"payload\":${payload}}"

  print -r -u "$tcp_fd" -- "$request"

  _COPILOT_ZLE_USING_DAEMON=1
  zle -F "$tcp_fd" _copilot_zle_autofix_result_handler
}

_copilot_zle_autofix_result_handler() {
  local fd=$1

  if [[ -z "$2" || "$2" == "hup" ]]; then
    local ec="" err="" cmd=""
    read -r -u $fd ec 2>/dev/null
    read -r -u $fd err 2>/dev/null
    IFS='' read -rd '' -u $fd cmd 2>/dev/null

    if [[ -n "$cmd" ]]; then
      if [[ "$_COPILOT_ZLE_CFG_AUTOFIX_MODE" == "ghost" ]]; then
        _copilot_zle_ghost_render "$cmd"
      else
        _copilot_zle_fix_message "$_COPILOT_ZLE_LAST_EXECUTED_COMMAND -> $cmd  (Ctrl+G to apply)"
        _COPILOT_ZLE_LAST_AI_COMMAND="$cmd"
        _COPILOT_ZLE_LAST_AI_PROMPT="fix the last command that failed"
      fi
      zle -R
    fi
  fi

  ztcp -c "$fd" 2>/dev/null
  zle -F "$fd" 2>/dev/null
}
zle -N _copilot_zle_autofix_result_handler

add-zsh-hook precmd _copilot_zle_autofix_precmd

# ── Mode Detection (SAM-39/40/41) ───────────────────────────────────
_copilot_zle_detect_mode() {
  local buffer="$1"
  if [[ -z "$buffer" && "$_COPILOT_ZLE_LAST_EXIT_CODE" != "0" && -n "$_COPILOT_ZLE_LAST_EXECUTED_COMMAND" ]]; then
    echo "fix"
    return
  fi
  if [[ -n "$buffer" && -n "$_COPILOT_ZLE_LAST_AI_COMMAND" ]]; then
    local lower="${(L)buffer}"
    # Chain mode: extend prior command with a pipe or step
    case "$lower" in
      pipe*|then*|"now pipe"*|"and pipe"*|"now sort"*|"now filter"*|"now count"*|"pipe that"*)
        echo "chain"
        return
        ;;
    esac
    case "$lower" in
      but*|also*|instead*|actually*|change*|make\ it*|add*|remove*|use*|with*|without*|try*|now*|and\ also*)
        echo "refine"
        return
        ;;
    esac
  fi
  echo "generate"
}

# ── Payload Builder (SAM-39/44) ─────────────────────────────────────
_copilot_zle_build_payload() {
  local prompt="$1"
  local mode="$2"

  local history_count
  history_count="$(_copilot_zle_read_config '.context.recentHistoryCount' '5')"
  local include_git
  include_git="$(_copilot_zle_read_config '.context.includeGitSummary' 'true')"
  local include_failure
  include_failure="$(_copilot_zle_read_config '.context.includeLastFailure' 'true')"

  local recent_history=""
  if (( history_count > 0 )); then
    if (( $+commands[fc] )) || whence -w fc >/dev/null 2>&1; then
      recent_history="$(fc -l -${history_count} 2>/dev/null | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//' || echo "")"
    fi
  fi

  local git_summary=""
  if [[ "$include_git" == "true" ]]; then
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      local branch dirty=""
      branch="$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || echo "detached")"
      if ! git diff --quiet HEAD 2>/dev/null; then
        dirty=" [dirty]"
      fi
      git_summary="${branch}${dirty}"
    fi
  fi

  local last_failure=""
  if [[ "$mode" == "fix" && "$include_failure" == "true" ]]; then
    last_failure="$_COPILOT_ZLE_LAST_EXECUTED_COMMAND (exit $_COPILOT_ZLE_LAST_EXIT_CODE)"
  fi

  local last_stderr=""
  if [[ "$mode" == "fix" && -n "$_COPILOT_ZLE_LAST_STDERR" ]]; then
    last_stderr="$_COPILOT_ZLE_LAST_STDERR"
  fi

  local prior_prompt="" prior_command=""
  if [[ "$mode" == "refine" || "$mode" == "chain" ]]; then
    prior_prompt="$_COPILOT_ZLE_LAST_AI_PROMPT"
    prior_command="$_COPILOT_ZLE_LAST_AI_COMMAND"
  fi

  # Environment context — critical for daemon which has stale process.env
  local in_git_repo="false"
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    in_git_repo="true"
  fi

  # Gather key aliases (ls, cat, grep, find, du — the ones the model should prefer)
  local alias_context=""
  alias_context="$(alias ls cat grep find du 2>/dev/null | head -20 || echo "")"

  jq -n -c \
    --arg prompt "$prompt" \
    --arg mode "$mode" \
    --arg recent_history "$recent_history" \
    --arg git_summary "$git_summary" \
    --arg last_failure "$last_failure" \
    --arg last_stderr "$last_stderr" \
    --arg prior_prompt "$prior_prompt" \
    --arg prior_command "$prior_command" \
    --arg cwd "$PWD" \
    --arg home "$HOME" \
    --arg dotfiles "${DOTFILES:-$HOME/.dotfiles}" \
    --arg shell "${SHELL:-zsh}" \
    --arg term_program "${TERM_PROGRAM:-unknown}" \
    --arg in_git_repo "$in_git_repo" \
    --arg alias_context "$alias_context" \
    '{
      prompt: $prompt,
      mode: $mode,
      recentHistory: $recent_history,
      gitSummary: $git_summary,
      lastFailure: $last_failure,
      lastStderr: $last_stderr,
      priorAi: {
        prompt: $prior_prompt,
        command: $prior_command
      },
      cwd: $cwd,
      home: $home,
      dotfiles: $dotfiles,
      shell: $shell,
      termProgram: $term_program,
      inGitRepo: $in_git_repo,
      aliasContextRaw: $alias_context
    }'
}

# ── Copilot Preflight Checks ────────────────────────────────────────
# Returns 0 if all prerequisites are met, 1 otherwise.
_copilot_zle_preflight() {
  local helpers_dir
  helpers_dir="$(_copilot_zle_helpers_dir)"
  if [[ ! -f "$helpers_dir/copilot-helper.mjs" ]]; then
    _copilot_zle_error_message "${_COPILOT_ZLE_CFG_BRAND_PRODUCT_NAME} helper missing."
    return 1
  fi
  if [[ ! -d "$helpers_dir/node_modules/@github/copilot-sdk" ]]; then
    _copilot_zle_error_message "GitHub Copilot SDK not installed. Run npm ci in the plugin directory."
    return 1
  fi
  if [[ ! -x "$(command -v node)" ]]; then
    _copilot_zle_error_message "Node not found."
    return 1
  fi
  local node_major
  node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  if (( node_major < 20 )); then
    _copilot_zle_error_message "Node 20+ required for the GitHub Copilot SDK."
    return 1
  fi
  return 0
}

# ── Async Spinner Handler (SAM-45) ──────────────────────────────────
_copilot_zle_spinner_handler() {
  local fd="$1"
  local line=""
  if ! read -r -u "$fd" line 2>/dev/null; then
    # Spinner process ended (SIGPIPE from fd close or natural exit)
    zle -F "$fd" 2>/dev/null
    builtin exec {fd}<&- 2>/dev/null
    _COPILOT_ZLE_SPINNER_FD=""
    return
  fi
  if (( _COPILOT_ZLE_ASYNC_ACTIVE )); then
    _COPILOT_ZLE_SPINNER_IDX=$(( (_COPILOT_ZLE_SPINNER_IDX % ${#_COPILOT_ZLE_SPINNER_FRAMES[@]}) + 1 ))
    _copilot_zle_status_message "${_COPILOT_ZLE_SPINNER_FRAMES[$_COPILOT_ZLE_SPINNER_IDX]}"
    zle -R
  fi
}

# ── Async Result Handler (SAM-45) ───────────────────────────────────
# Pattern from zsh-autosuggestions: zle -F handlers CANNOT modify BUFFER
# directly — changes are discarded when the handler returns. Instead, store
# the result in globals and invoke a proper ZLE widget with `zle <name>`.
_copilot_zle_result_handler() {
  emulate -L zsh
  local fd=$1

  # Stop spinner
  _COPILOT_ZLE_ASYNC_ACTIVE=0
  if [[ -n "$_COPILOT_ZLE_SPINNER_FD" ]]; then
    zle -F "$_COPILOT_ZLE_SPINNER_FD" 2>/dev/null
    builtin exec {_COPILOT_ZLE_SPINNER_FD}<&- 2>/dev/null
    _COPILOT_ZLE_SPINNER_FD=""
  fi

  if [[ -z "$2" || "$2" == "hup" ]]; then
    # Read pre-extracted fields directly from the pipe (builtins only).
    # Format: line 1 = error_code, line 2 = error, rest = command.
    read -r -u $fd _COPILOT_ZLE_PENDING_EC 2>/dev/null
    read -r -u $fd _COPILOT_ZLE_PENDING_ERR 2>/dev/null
    IFS='' read -rd '' -u $fd _COPILOT_ZLE_PENDING_CMD 2>/dev/null

    _copilot_zle_debug_log "pipe read: cmd='${_COPILOT_ZLE_PENDING_CMD}' ec='${_COPILOT_ZLE_PENDING_EC}' err='${_COPILOT_ZLE_PENDING_ERR}'"

    # Apply result via proper ZLE widget — only way BUFFER changes persist
    zle _copilot_zle_apply_result
  fi

  # Clean up fd
  if (( _COPILOT_ZLE_USING_DAEMON )); then
    ztcp -c "$fd" 2>/dev/null
  else
    builtin exec {fd}<&- 2>/dev/null
  fi
  zle -F "$fd" 2>/dev/null
  _COPILOT_ZLE_RESULT_FD=""
}

# ── Apply Result Widget ─────────────────────────────────────────────
# Registered as a ZLE widget so BUFFER modifications persist (the correct
# async pattern, matching zsh-autosuggestions).
_copilot_zle_apply_result() {
  local command="$_COPILOT_ZLE_PENDING_CMD"
  local error="$_COPILOT_ZLE_PENDING_ERR"
  local error_code="$_COPILOT_ZLE_PENDING_EC"
  local mode="$_COPILOT_ZLE_ASYNC_MODE"

  _COPILOT_ZLE_PENDING_CMD=""
  _COPILOT_ZLE_PENDING_ERR=""
  _COPILOT_ZLE_PENDING_EC=""

  _copilot_zle_debug_log "apply_result widget: cmd_len=${#command} ec='$error_code' mode=$mode"

  if [[ -z "$command" ]]; then
    case "$error_code" in
      copilot_cli_missing)
        _copilot_zle_error_message "Required CLI dependency missing."
        ;;
      copilot_auth_required)
        _copilot_zle_error_message "GitHub Copilot auth required."
        ;;
      copilot_model_rejected)
        _copilot_zle_error_message "Model rejected: $COPILOT_ZLE_MODEL"
        ;;
      copilot_timeout)
        _copilot_zle_error_message "${_COPILOT_ZLE_CFG_BRAND_PRODUCT_NAME} request timed out."
        ;;
      copilot_sdk_missing)
        _copilot_zle_error_message "GitHub Copilot SDK not installed. Run npm ci in the plugin directory."
        ;;
      copilot_node_required)
        _copilot_zle_error_message "Node 20+ required for the GitHub Copilot SDK."
        ;;
      *)
        if [[ -n "$error" ]]; then
          _copilot_zle_error_message "${_COPILOT_ZLE_CFG_BRAND_PRODUCT_NAME} failed. Check $COPILOT_ZLE_DEBUG_LOG"
        else
          _copilot_zle_error_message "No command returned."
        fi
        ;;
    esac
    zle -R
    return
  fi

  # Store AI state for future refinement (SAM-41)
  _COPILOT_ZLE_LAST_AI_PROMPT="$_COPILOT_ZLE_ASYNC_EFFECTIVE_PROMPT"
  _COPILOT_ZLE_LAST_AI_COMMAND="$command"

  # Dry validation: check if the primary binary exists
  local _copilot_dry_warn=""
  local _copilot_first_token="${command%% *}"
  # Strip leading env assignments (VAR=val cmd)
  if [[ "$_copilot_first_token" == *=* ]]; then
    local _copilot_rest="${command#*= }"
    _copilot_first_token="${_copilot_rest%% *}"
  fi
  # Strip "command " prefix
  if [[ "$_copilot_first_token" == "command" ]]; then
    local _copilot_rest="${command#command }"
    _copilot_first_token="${_copilot_rest%% *}"
  fi
  if [[ -n "$_copilot_first_token" ]] && \
     ! (( $+commands[$_copilot_first_token] )) && \
     ! (( $+aliases[$_copilot_first_token] )) && \
     ! (( $+functions[$_copilot_first_token] )) && \
     ! whence -w "$_copilot_first_token" >/dev/null 2>&1; then
    _copilot_dry_warn=" [WARN: '$_copilot_first_token' NOT FOUND]"
  fi

  # Set buffer and cursor
  BUFFER="$command"
  CURSOR=${#BUFFER}

  # Store candidates for cycling (daemon may return extras via _COPILOT_ZLE_PENDING_CANDIDATES)
  _COPILOT_ZLE_CANDIDATES=("$command")
  _COPILOT_ZLE_CANDIDATE_IDX=1

  _copilot_zle_debug_log "BUFFER set: len=${#BUFFER}"

  # Apply visual highlight using cached config (SAM-42/44)
  if [[ "$_COPILOT_ZLE_CFG_HIGHLIGHT_ENABLED" == "true" && "$_COPILOT_ZLE_CFG_HIGHLIGHT_STYLE" != "none" ]]; then
    _COPILOT_ZLE_GENERATED_BUFFER="$BUFFER"
    region_highlight=("0 ${#BUFFER} ${_COPILOT_ZLE_CFG_HIGHLIGHT_STYLE}")
  fi

  case "$mode" in
    fix)
      _copilot_zle_status_message "FIX APPLIED. REVIEW BEFORE EXECUTION.${_copilot_dry_warn}"
      ;;
    refine)
      _copilot_zle_status_message "COMMAND REFINED. REVIEW BEFORE EXECUTION.${_copilot_dry_warn}"
      ;;
    chain)
      _copilot_zle_status_message "PIPELINE EXTENDED. REVIEW BEFORE EXECUTION.${_copilot_dry_warn}"
      ;;
    *)
      _copilot_zle_status_message "COMMAND RECEIVED. REVIEW BEFORE EXECUTION.${_copilot_dry_warn}"
      ;;
  esac
  zle -R
}
zle -N _copilot_zle_apply_result

# ── Cancel In-Flight Request ────────────────────────────────────────
_copilot_zle_cancel_async() {
  if (( ! _COPILOT_ZLE_ASYNC_ACTIVE )); then
    return
  fi
  _COPILOT_ZLE_ASYNC_ACTIVE=0
  if [[ -n "$_COPILOT_ZLE_RESULT_FD" ]]; then
    zle -F "$_COPILOT_ZLE_RESULT_FD" 2>/dev/null
    builtin exec {_COPILOT_ZLE_RESULT_FD}<&- 2>/dev/null
    _COPILOT_ZLE_RESULT_FD=""
  fi
  if [[ -n "$_COPILOT_ZLE_SPINNER_FD" ]]; then
    zle -F "$_COPILOT_ZLE_SPINNER_FD" 2>/dev/null
    builtin exec {_COPILOT_ZLE_SPINNER_FD}<&- 2>/dev/null
    _COPILOT_ZLE_SPINNER_FD=""
  fi
  _copilot_zle_status_message "REQUEST CANCELLED."
  zle -R
}

# ── Daemon Request Path ──────────────────────────────────────────────
_copilot_zle_send_via_daemon() {
  local payload="$1" mode="$2"
  local helpers_dir
  helpers_dir="$(_copilot_zle_helpers_dir)"

  zmodload -e zsh/net/tcp || zmodload zsh/net/tcp 2>/dev/null || return 1

  ztcp 127.0.0.1 "$_COPILOT_ZLE_DAEMON_PORT" 2>/dev/null || return 1
  local tcp_fd=$REPLY
  _COPILOT_ZLE_USING_DAEMON=1

  local request="{\"id\":${RANDOM},\"type\":\"generate\",\"format\":\"zle\",\"payload\":${payload}}"
  print -r -u "$tcp_fd" -- "$request"

  _copilot_zle_debug_log "daemon request sent on fd=$tcp_fd"

  _COPILOT_ZLE_RESULT_FD=$tcp_fd
  zle -F "$tcp_fd" _copilot_zle_result_handler
  return 0
}

# ── Subprocess Request Path (fallback) ───────────────────────────────
_copilot_zle_send_via_subprocess() {
  local payload="$1" mode="$2"
  local helpers_dir
  helpers_dir="$(_copilot_zle_helpers_dir)"
  local helper="$helpers_dir/copilot-helper.mjs"

  _COPILOT_ZLE_USING_DAEMON=0

  local stderr_target="/dev/null"
  if [[ -n "${COPILOT_ZLE_DEBUG:-}" ]]; then
    stderr_target="$COPILOT_ZLE_DEBUG_LOG"
  fi
  builtin exec {_COPILOT_ZLE_RESULT_FD}< <(
    local raw
    raw="$(printf '%s' "$payload" | COPILOT_ZLE_DEBUG="${COPILOT_ZLE_DEBUG:-}" NODE_NO_WARNINGS=1 node "$helper" 2>>"$stderr_target")"
    local ec err cmd
    ec="$(printf '%s' "$raw" | jq -r '.error_code // empty' 2>/dev/null)"
    err="$(printf '%s' "$raw" | jq -r '.error // empty' 2>/dev/null)"
    cmd="$(printf '%s' "$raw" | jq -r '.command // empty' 2>/dev/null)"
    printf '%s\n' "$ec"
    printf '%s\n' "$err"
    printf '%s' "$cmd"
  )
  zle -F "$_COPILOT_ZLE_RESULT_FD" _copilot_zle_result_handler

  _copilot_zle_debug_log "subprocess result fd=$_COPILOT_ZLE_RESULT_FD launched"
}

# ── Main ZLE Widget ─────────────────────────────────────────────────
typeset -g _COPILOT_ZLE_ASYNC_EFFECTIVE_PROMPT=""

copilot_zle_generate() {
  # If a request is already in flight, cancel it first
  if (( _COPILOT_ZLE_ASYNC_ACTIVE )); then
    _copilot_zle_cancel_async
    return
  fi

  # Clear any ghost-text suggestion
  _copilot_zle_ghost_clear

  local user_input="${BUFFER}"

  _copilot_zle_debug_log "widget fired: BUFFER='$user_input'"

  if [[ ! -x "$(command -v jq)" ]]; then
    _copilot_zle_error_message "jq not found."
    return
  fi

  # Preflight checks
  _copilot_zle_preflight || return

  _copilot_zle_debug_log "preflight passed"

  # Detect mode (SAM-39/40/41)
  local mode
  mode="$(_copilot_zle_detect_mode "$user_input")"

  _copilot_zle_debug_log "mode=$mode"

  # Determine the effective prompt
  local effective_prompt=""
  case "$mode" in
    fix)
      # If autofix already found a fix, apply it directly
      if [[ -n "$_COPILOT_ZLE_LAST_AI_COMMAND" && "$_COPILOT_ZLE_LAST_AI_PROMPT" == "fix the last command that failed" ]]; then
        BUFFER="$_COPILOT_ZLE_LAST_AI_COMMAND"
        CURSOR=${#BUFFER}
        _COPILOT_ZLE_GENERATED_BUFFER="$BUFFER"
        if [[ "$_COPILOT_ZLE_CFG_HIGHLIGHT_ENABLED" == "true" && "$_COPILOT_ZLE_CFG_HIGHLIGHT_STYLE" != "none" ]]; then
          region_highlight=("0 ${#BUFFER} ${_COPILOT_ZLE_CFG_HIGHLIGHT_STYLE}")
        fi
        _copilot_zle_status_message "FIX APPLIED. REVIEW BEFORE EXECUTION."
        zle -R
        _copilot_zle_debug_log "fix shortcut: applied cached fix '$_COPILOT_ZLE_LAST_AI_COMMAND'"
        return
      fi
      effective_prompt="fix the last command that failed"
      _copilot_zle_status_message "FIX MODE: ANALYZING FAILED COMMAND..."
      ;;
    refine)
      effective_prompt="$user_input"
      _copilot_zle_status_message "REFINE MODE: ADJUSTING PRIOR COMMAND..."
      ;;
    chain)
      effective_prompt="$user_input"
      _copilot_zle_status_message "CHAIN MODE: EXTENDING PIPELINE..."
      ;;
    generate)
      if [[ -z "$user_input" ]]; then
        if [[ -n "$_COPILOT_ZLE_LAST_AI_QUERY" ]]; then
          user_input="$_COPILOT_ZLE_LAST_AI_QUERY"
          effective_prompt="$user_input"
          _copilot_zle_status_message "RETRYING LAST QUERY: $user_input"
        else
          return
        fi
      else
        effective_prompt="$user_input"
        _COPILOT_ZLE_LAST_AI_QUERY="$user_input"
        _copilot_zle_status_message "${_COPILOT_ZLE_CFG_BRAND_THINKING_LABEL}..."
      fi
      ;;
  esac

  # Store for result handler
  _COPILOT_ZLE_ASYNC_EFFECTIVE_PROMPT="$effective_prompt"

  # Build structured payload (SAM-39)
  local payload
  payload="$(_copilot_zle_build_payload "$effective_prompt" "$mode")"
  _copilot_zle_debug_log "payload: $payload"

  if [[ -z "$payload" ]]; then
    _copilot_zle_error_message "Payload build failed."
    return
  fi

  # Launch async (SAM-45)
  _COPILOT_ZLE_ASYNC_MODE="$mode"
  _COPILOT_ZLE_ASYNC_ACTIVE=1
  _COPILOT_ZLE_SPINNER_IDX=0

  # Spinner subprocess: writes a line every 300ms for zle -F to pick up
  builtin exec {_COPILOT_ZLE_SPINNER_FD}< <(
    while true; do
      sleep 0.3
      printf 'tick\n'
    done
  )
  zle -F "$_COPILOT_ZLE_SPINNER_FD" _copilot_zle_spinner_handler

  _copilot_zle_debug_log "spinner fd=$_COPILOT_ZLE_SPINNER_FD"

  # Try daemon first, fall back to subprocess
  if _copilot_zle_daemon_ensure 2>/dev/null && \
     _copilot_zle_send_via_daemon "$payload" "$mode" 2>/dev/null; then
    _copilot_zle_debug_log "using daemon on port $_COPILOT_ZLE_DAEMON_PORT"
  else
    _copilot_zle_send_via_subprocess "$payload" "$mode"
  fi

  zle -R
}

# ── Explain Mode Widget ──────────────────────────────────────────────
_copilot_zle_explain_result_handler() {
  local fd=$1
  if [[ -z "$2" || "$2" == "hup" ]]; then
    local skip1="" skip2="" explanation=""
    read -r -u $fd skip1 2>/dev/null
    read -r -u $fd skip2 2>/dev/null
    IFS='' read -rd '' -u $fd explanation 2>/dev/null

    if [[ -n "$explanation" ]]; then
      _copilot_zle_explain_message "$explanation"
    else
      _copilot_zle_explain_message "No explanation available."
    fi
    zle -R
  fi

  if (( _COPILOT_ZLE_USING_DAEMON )); then
    ztcp -c "$fd" 2>/dev/null
  else
    builtin exec {fd}<&- 2>/dev/null
  fi
  zle -F "$fd" 2>/dev/null
}
zle -N _copilot_zle_explain_result_handler

copilot_zle_explain() {
  local command="$BUFFER"
  if [[ -z "$command" ]]; then
    _copilot_zle_explain_message "Empty buffer. Type a command first."
    return
  fi

  _copilot_zle_explain_message "Analyzing..."
  zle -R

  # Need daemon for explain
  if ! _copilot_zle_daemon_ensure 2>/dev/null; then
    _copilot_zle_explain_message "Daemon unavailable."
    return
  fi

  zmodload -e zsh/net/tcp || zmodload zsh/net/tcp 2>/dev/null || return

  ztcp 127.0.0.1 "$_COPILOT_ZLE_DAEMON_PORT" 2>/dev/null || {
    _copilot_zle_explain_message "Daemon connection failed."
    return
  }
  local tcp_fd=$REPLY

  local escaped_cmd
  escaped_cmd="$(printf '%s' "$command" | jq -Rs '.' 2>/dev/null || echo '""')"

  local request="{\"id\":${RANDOM},\"type\":\"explain\",\"format\":\"zle\",\"payload\":{\"command\":${escaped_cmd},\"cwd\":\"${PWD}\",\"home\":\"${HOME}\"}}"
  print -r -u "$tcp_fd" -- "$request"

  _COPILOT_ZLE_USING_DAEMON=1
  zle -F "$tcp_fd" _copilot_zle_explain_result_handler
}

# ── Key Bindings ─────────────────────────────────────────────────────
zle -N copilot_zle_generate
zle -N copilot_zle_explain
zle -N copilot_zle_help
bindkey '^g' copilot_zle_generate
bindkey '^e' copilot_zle_explain
bindkey '^[h' copilot_zle_help 2>/dev/null || true
bindkey '^[H' copilot_zle_help 2>/dev/null || true
bindkey '^Xh' copilot_zle_help 2>/dev/null || true
bindkey '^XH' copilot_zle_help 2>/dev/null || true
bindkey -M viins '^g' copilot_zle_generate 2>/dev/null || true
bindkey -M vicmd '^g' copilot_zle_generate 2>/dev/null || true
bindkey -M viins '^e' copilot_zle_explain 2>/dev/null || true
bindkey -M vicmd '^e' copilot_zle_explain 2>/dev/null || true
bindkey -M viins '^[h' copilot_zle_help 2>/dev/null || true
bindkey -M vicmd '^[h' copilot_zle_help 2>/dev/null || true
bindkey -M viins '^[H' copilot_zle_help 2>/dev/null || true
bindkey -M vicmd '^[H' copilot_zle_help 2>/dev/null || true
bindkey -M viins '^Xh' copilot_zle_help 2>/dev/null || true
bindkey -M vicmd '^Xh' copilot_zle_help 2>/dev/null || true
bindkey -M viins '^XH' copilot_zle_help 2>/dev/null || true
bindkey -M vicmd '^XH' copilot_zle_help 2>/dev/null || true
# Ghost-text: right-arrow or Ctrl+F to accept full suggestion
bindkey '^[OC' _copilot_zle_ghost_accept_full 2>/dev/null || true  # Right arrow
bindkey '^[[C' _copilot_zle_ghost_accept_full 2>/dev/null || true  # Right arrow (alt)
bindkey '^F' _copilot_zle_ghost_accept_full 2>/dev/null || true    # Ctrl+F
# Ghost-text: Ctrl+Right to accept word-by-word
bindkey '^[[1;5C' _copilot_zle_ghost_accept_word 2>/dev/null || true  # Ctrl+Right
