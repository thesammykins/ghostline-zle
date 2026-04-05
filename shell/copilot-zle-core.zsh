# copilot-zle-core.zsh - internal Ghostline shell core
# Generates shell commands from natural language without leaving the prompt.
# Engine: Copilot SDK
# Model: gpt-5-mini

if [[ -n "${_COPILOT_ZLE_CORE_LOADED_FROM:-}" ]]; then
  if [[ "${_COPILOT_ZLE_CORE_LOADED_FROM}" != "${(%):-%N}" ]]; then
    print -u2 -- "copilot-zle: shell core already loaded from ${_COPILOT_ZLE_CORE_LOADED_FROM}; skipping duplicate source from ${(%):-%N}"
  fi
  return 0
fi
typeset -g _COPILOT_ZLE_CORE_LOADED_FROM="${(%):-%N}"

if [[ -z "${COPILOT_ZLE_ROOT_DIR:-}" ]]; then
  typeset -g _COPILOT_ZLE_CORE_PATH="${(%):-%N}"
  export COPILOT_ZLE_ROOT_DIR="${_COPILOT_ZLE_CORE_PATH:A:h:h}"
fi

# ── Configuration ────────────────────────────────────────────────────
export COPILOT_ZLE_TIMEOUT_MS="${COPILOT_ZLE_TIMEOUT_MS:-30000}"
export COPILOT_ZLE_MODEL="${COPILOT_ZLE_MODEL:-}"
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
typeset -g  _COPILOT_ZLE_RESULT_PID=""
typeset -g  _COPILOT_ZLE_RESULT_FILE=""
typeset -g  _COPILOT_ZLE_SPINNER_FD=""
# Pending result (written by zle -F handler, consumed by apply widget)
typeset -g  _COPILOT_ZLE_PENDING_CMD=""
typeset -g  _COPILOT_ZLE_PENDING_EC=""
typeset -g  _COPILOT_ZLE_PENDING_ERR=""
typeset -g  _COPILOT_ZLE_PENDING_RAW=""
# Cached UI config (read once at load, avoids forking jq inside zle -F handlers)
typeset -g  _COPILOT_ZLE_CFG_MODEL_DEFAULT=""
typeset -g  _COPILOT_ZLE_CFG_HIGHLIGHT_ENABLED=""
typeset -g  _COPILOT_ZLE_CFG_HIGHLIGHT_STYLE=""
typeset -gi _COPILOT_ZLE_CFG_CONTEXT_HISTORY_COUNT=5
typeset -g  _COPILOT_ZLE_CFG_CONTEXT_INCLUDE_GIT=""
typeset -g  _COPILOT_ZLE_CFG_CONTEXT_INCLUDE_FAILURE=""
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
# Flight log + queued prompt message tracking
typeset -g  _COPILOT_ZLE_TRACKING_EXECUTION=""
typeset -g  _COPILOT_ZLE_LAST_HANDOFF_PROMPT=""
typeset -gi _COPILOT_ZLE_REQUEST_STARTED_AT=0
typeset -g  _COPILOT_ZLE_LAST_GIT_CWD=""
typeset -g  _COPILOT_ZLE_LAST_GIT_SUMMARY=""
typeset -g  _COPILOT_ZLE_LAST_GIT_IN_REPO="false"
typeset -g  _COPILOT_ZLE_LAST_ALIAS_CONTEXT=""

# ── Hooks: track last command, exit code, and stderr (SAM-40) ────────
autoload -Uz add-zsh-hook
zmodload zsh/datetime 2>/dev/null || true

_copilot_zle_preexec() {
  _copilot_zle_clear_prompt_state
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

if [[ -z "${_COPILOT_ZLE_HOOKS_REGISTERED:-}" ]]; then
  add-zsh-hook preexec _copilot_zle_preexec
  add-zsh-hook precmd  _copilot_zle_precmd
  typeset -g _COPILOT_ZLE_HOOKS_REGISTERED=1
fi

# ── Highlight + ghost-text clear hook ─────────────────────────────────
if [[ -z "${_COPILOT_ZLE_ZLE_HOOKS_REGISTERED:-}" ]] && autoload -Uz add-zle-hook-widget 2>/dev/null; then
  add-zle-hook-widget line-init _copilot_zle_flush_pending_message 2>/dev/null || true
  add-zle-hook-widget line-pre-redraw _copilot_zle_ghost_line_changed 2>/dev/null || true
  add-zle-hook-widget line-pre-redraw _copilot_zle_flush_pending_message 2>/dev/null || true
  typeset -g _COPILOT_ZLE_ZLE_HOOKS_REGISTERED=1
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
  if [[ -n "${COPILOT_ZLE_ROOT_DIR:-}" ]]; then
    echo "${COPILOT_ZLE_ROOT_DIR:A}"
    return
  fi
  local script_path
  script_path="$COPILOT_ZLE_PLUGIN_PATH"
  if [[ -z "$script_path" ]]; then
    script_path="${(%):-%x}"
  fi
  if [[ -z "$script_path" ]]; then
    script_path="$0"
  fi
  local resolved_dir="${script_path:A:h}"
  if [[ "${resolved_dir:t}" == "shell" ]]; then
    echo "${resolved_dir:h}"
    return
  fi
  echo "$resolved_dir"
}

if [[ ! -f "$(_copilot_zle_helpers_dir)/shell/nl-detection.zsh" ]]; then
  print -u2 -- "copilot-zle: missing NL detection helper at $(_copilot_zle_helpers_dir)/shell/nl-detection.zsh"
  return 1
fi
source "$(_copilot_zle_helpers_dir)/shell/nl-detection.zsh"

if [[ ! -f "$(_copilot_zle_helpers_dir)/shell/message-queue.zsh" ]]; then
  print -u2 -- "copilot-zle: missing message queue helper at $(_copilot_zle_helpers_dir)/shell/message-queue.zsh"
  return 1
fi
source "$(_copilot_zle_helpers_dir)/shell/message-queue.zsh"

if [[ ! -f "$(_copilot_zle_helpers_dir)/shell/failure-indicator.zsh" ]]; then
  print -u2 -- "copilot-zle: missing failure indicator helper at $(_copilot_zle_helpers_dir)/shell/failure-indicator.zsh"
  return 1
fi
source "$(_copilot_zle_helpers_dir)/shell/failure-indicator.zsh"

_copilot_zle_debug_log() {
  if [[ -n "${COPILOT_ZLE_DEBUG:-}" ]]; then
    printf '%s\n' "$1" >> "$COPILOT_ZLE_DEBUG_LOG"
  fi
}

_copilot_zle_flush_pending_message() {
  local message=""
  message="$(_copilot_zle_take_pending_message 2>/dev/null)" || return 0
  [[ -n "$message" ]] || return 0
  zle -M "$message" 2>/dev/null || true
}

_copilot_zle_show_message() {
  local prefix="$1" body="$2"
  local message="$prefix"
  if [[ -n "$body" ]]; then
    message="$prefix $body"
  fi
  if zle -M "$message" 2>/dev/null; then
    return
  fi
  _copilot_zle_set_pending_message "$prefix" "$body"
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

_copilot_zle_capture_tty_state() {
  stty -g 2>/dev/null || true
}

_copilot_zle_restore_tty_state() {
  local tty_state="$1"
  [[ -n "$tty_state" ]] || return 0
  stty "$tty_state" 2>/dev/null || true
}

_copilot_zle_reload_cached_config() {
  _COPILOT_ZLE_CFG_MODEL_DEFAULT="$(_copilot_zle_read_config '.model.default' 'gpt-5-mini')"
  _COPILOT_ZLE_CFG_HIGHLIGHT_ENABLED="$(_copilot_zle_read_config '.ui.highlightAiBuffer' 'true')"
  _COPILOT_ZLE_CFG_HIGHLIGHT_STYLE="$(_copilot_zle_read_config '.ui.highlightStyle' 'underline')"
  _COPILOT_ZLE_CFG_CONTEXT_HISTORY_COUNT="$(_copilot_zle_read_config '.context.recentHistoryCount' '5')"
  _COPILOT_ZLE_CFG_CONTEXT_INCLUDE_GIT="$(_copilot_zle_read_config '.context.includeGitSummary' 'true')"
  _COPILOT_ZLE_CFG_CONTEXT_INCLUDE_FAILURE="$(_copilot_zle_read_config '.context.includeLastFailure' 'true')"
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
  _copilot_zle_refresh_shell_context
}

_copilot_zle_effective_model() {
  if [[ -n "${COPILOT_ZLE_MODEL:-}" ]]; then
    echo "$COPILOT_ZLE_MODEL"
    return
  fi
  if [[ -n "$_COPILOT_ZLE_CFG_MODEL_DEFAULT" ]]; then
    echo "$_COPILOT_ZLE_CFG_MODEL_DEFAULT"
    return
  fi
  echo "gpt-5-mini"
}

_copilot_zle_json_get() {
  local raw="$1" filter="$2"
  [[ -n "$raw" ]] || return 0
  printf '%s' "$raw" | jq -r "$filter" 2>/dev/null
}

_copilot_zle_now_ms() {
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    printf '%.0f' "$(( EPOCHREALTIME * 1000 ))"
    return
  fi
  printf '%s000' "$(date +%s)"
}

_copilot_zle_clear_prompt_state() {
  unset GHOSTLINE_MODE GHOSTLINE_RISK GHOSTLINE_LATENCY GHOSTLINE_STATUS GHOSTLINE_PROMPT_STATUS
}

_copilot_zle_refresh_live_rprompt() {
  [[ -n "${WIDGET:-}" ]] || return 0

  if whence -w prompt_starship_precmd >/dev/null 2>&1; then
    prompt_starship_precmd 2>/dev/null || true
  fi

  if (( _COPILOT_ZLE_ASYNC_ACTIVE )) && [[ -n "${GHOSTLINE_PROMPT_STATUS:-}" ]]; then
    RPROMPT="${GHOSTLINE_PROMPT_STATUS}"
  elif [[ -n "${_COPILOT_ZLE_RPROMPT_BASE:-}" ]]; then
    RPROMPT="${_COPILOT_ZLE_RPROMPT_BASE}"
  else
    RPROMPT=""
  fi
}

_copilot_zle_can_reset_prompt() {
  [[ -n "${WIDGET:-}" ]] || return 1

  # Preserve the current input line while a request is still thinking, or when
  # an error leaves the user's original natural-language buffer in place.
  if (( _COPILOT_ZLE_ASYNC_ACTIVE )); then
    return 1
  fi

  [[ -n "${BUFFER:-}" ]] || return 0

  if [[ -n "$_COPILOT_ZLE_LAST_AI_COMMAND" && "$BUFFER" == "$_COPILOT_ZLE_LAST_AI_COMMAND" ]]; then
    return 0
  fi

  if [[ -n "$_COPILOT_ZLE_GENERATED_BUFFER" && "$BUFFER" == "$_COPILOT_ZLE_GENERATED_BUFFER" ]]; then
    return 0
  fi

  return 1
}

_copilot_zle_set_prompt_state() {
  local mode="$1" risk="$2" latency="$3"
  if [[ -n "$mode" ]]; then
    export GHOSTLINE_MODE="$mode"
  else
    unset GHOSTLINE_MODE
  fi
  if [[ -n "$risk" ]]; then
    export GHOSTLINE_RISK="$risk"
  else
    unset GHOSTLINE_RISK
  fi
  if [[ -n "$latency" ]]; then
    export GHOSTLINE_LATENCY="$latency"
  else
    unset GHOSTLINE_LATENCY
  fi
  if [[ -n "$mode" ]]; then
    local status_text="AI ${mode}"
    local prompt_icon=""
    local prompt_mode="${(L)mode}"
    local prompt_status=""
    case "$mode" in
      GEN) prompt_mode="gen" ;;
      REF) prompt_mode="ref" ;;
      CHAIN) prompt_mode="pipe" ;;
      FIX) prompt_mode="fix" ;;
      OC) prompt_mode="oc" ;;
    esac
    if [[ -n "$risk" ]]; then
      status_text="${status_text} ${risk}"
    fi
    if [[ -n "$latency" ]]; then
      status_text="${status_text} ${latency}"
    fi
    export GHOSTLINE_STATUS="$status_text"
    prompt_status="${prompt_icon} ${prompt_mode}"
    if [[ -n "$risk" ]]; then
      prompt_status="${prompt_status} ${(L)risk}"
    fi
    if [[ -n "$latency" ]]; then
      prompt_status="${prompt_status} ${latency}"
    fi
    export GHOSTLINE_PROMPT_STATUS="$prompt_status"
  else
    export GHOSTLINE_STATUS="AI IDLE"
    export GHOSTLINE_PROMPT_STATUS=" idle"
  fi

  _copilot_zle_refresh_live_rprompt

  if _copilot_zle_can_reset_prompt; then
    zle reset-prompt 2>/dev/null || zle -R 2>/dev/null || true
  else
    _copilot_zle_refresh_live_rprompt
  fi

}

_copilot_zle_refresh_shell_context() {
  _COPILOT_ZLE_LAST_ALIAS_CONTEXT="$(alias ls cat grep find du 2>/dev/null || true)"

  if [[ "$_COPILOT_ZLE_CFG_CONTEXT_INCLUDE_GIT" != "true" ]]; then
    _COPILOT_ZLE_LAST_GIT_CWD="$PWD"
    _COPILOT_ZLE_LAST_GIT_SUMMARY=""
    _COPILOT_ZLE_LAST_GIT_IN_REPO="false"
    return
  fi

  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local branch dirty=""
    branch="$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || print detached)"
    if ! git diff --quiet HEAD 2>/dev/null; then
      dirty=" [dirty]"
    fi
    _COPILOT_ZLE_LAST_GIT_CWD="$PWD"
    _COPILOT_ZLE_LAST_GIT_SUMMARY="${branch}${dirty}"
    _COPILOT_ZLE_LAST_GIT_IN_REPO="true"
    return
  fi

  _COPILOT_ZLE_LAST_GIT_CWD="$PWD"
  _COPILOT_ZLE_LAST_GIT_SUMMARY=""
  _COPILOT_ZLE_LAST_GIT_IN_REPO="false"
}

_copilot_zle_mode_label() {
  case "$1" in
    fix) print -r -- "FIX" ;;
    refine) print -r -- "REF" ;;
    chain) print -r -- "CHAIN" ;;
    handoff) print -r -- "OC" ;;
    *) print -r -- "GEN" ;;
  esac
}

_copilot_zle_command_risk() {
  local text="${(L)1}"
  case "$text" in
    *"rm -rf"*|*"mkfs"*|*"dd if="*|*"shutdown"*|*"reboot"*|*"poweroff"*|*"diskutil erase"*)
      print -r -- "DEST"
      return
      ;;
  esac
  case "$text" in
    sudo\ *|*" sudo "*)
      print -r -- "ROOT"
      return
      ;;
  esac
  case "$text" in
    *"curl "*|*"wget "*|*"ssh "*|*"scp "*|*"rsync "*|*"nc "*|*"ping "*|*"dig "*|*"nslookup "*)
      print -r -- "NET"
      return
      ;;
  esac
  case "$text" in
    *">"*|*">>"*|*" tee "*|*" mv "*|*" cp "*|*"mkdir "*|*"touch "*|*"chmod "*|*"chown "*|*"sed -i"*|*"perl -pi"*|*"npm install"*|*"brew install"*|*"git add "*|*"git commit"*|*"git push"*|*"git checkout "*|*"git switch "*|*"git restore "*|*"git reset "*)
      print -r -- "MOD"
      return
      ;;
  esac
  print -r -- ""
}

_copilot_zle_should_handoff_to_opencode() {
  local prompt="${(L)1}"
  [[ -n "$prompt" ]] || return 1
  case "$prompt" in
    *"implement "*|*"debug "*|*"diagnose "*|*"investigate "*|*"review "*|*"refactor "*|*"fix bug"*|*"fix this"*|*"why is "*|*"what's wrong"*|*"write a script"*|*"write me a script"*|*"add feature"*|*"create a tool"*|*"search code"*|*"find in repo"*|*"read the code"*|*"plan "*|*"set up "*|*"configure "*|*"build me "*)
      return 0
      ;;
  esac
  return 1
}

_copilot_zle_opencode_runner() {
  local dotfiles_root="${DOTFILES:-$HOME/.dotfiles}"
  if [[ -x "$dotfiles_root/scripts/run-opencode.sh" ]]; then
    print -r -- "$dotfiles_root/scripts/run-opencode.sh"
    return 0
  fi
  if [[ -x "$(command -v opencode)" ]]; then
    print -r -- "$(command -v opencode)"
    return 0
  fi
  return 1
}

copilot_zle_handoff_opencode() {
  local prompt="$BUFFER"
  [[ -n "$prompt" ]] || prompt="${_COPILOT_ZLE_LAST_HANDOFF_PROMPT:-$_COPILOT_ZLE_LAST_AI_QUERY}"

  local runner
  runner="$(_copilot_zle_opencode_runner 2>/dev/null)" || {
    _copilot_zle_error_message "opencode not found."
    return 1
  }

  local -a cmd
  cmd=("$runner" "$PWD")
  if [[ -n "$prompt" ]]; then
    cmd+=(--prompt "$prompt")
  fi

  _COPILOT_ZLE_LAST_HANDOFF_PROMPT=""
  local tty_state
  tty_state="$(_copilot_zle_capture_tty_state)"
  zle -I
  print -r -- ""
  print -r -- "opening opencode..."
  command "${cmd[@]}"
  _copilot_zle_restore_tty_state "$tty_state"
  zle reset-prompt
  zle -R
}

_copilot_zle_build_request() {
  local type="$1" format="$2" payload_json="$3"
  [[ -n "$payload_json" ]] || return 1

  jq -n -c \
    --arg type "$type" \
    --arg format "$format" \
    --argjson id "${RANDOM:-0}" \
    --argjson payload "$payload_json" \
    '{ id: $id, type: $type, payload: $payload } + (if $format == "" then {} else { format: $format } end)'
}

# Cache UI config at load time (safe to fork jq here, outside ZLE context)
_copilot_zle_reload_cached_config

_copilot_zle_open_with_editor() {
  local target="$1" label="$2"
  [[ -n "$target" ]] || return 1

  local -a editor_cmd
  editor_cmd=( ${(z)${VISUAL:-${EDITOR:-vi}}} )
  (( ${#editor_cmd[@]} > 0 )) || editor_cmd=(vi)
  local tty_state
  tty_state="$(_copilot_zle_capture_tty_state)"

  zle -I
  print -r -- ""
  print -r -- "opening ${label} with ${editor_cmd[1]}..."
  command "${editor_cmd[@]}" "$target"
  _copilot_zle_restore_tty_state "$tty_state"
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
  local tty_state
  tty_state="$(_copilot_zle_capture_tty_state)"

  zle -I
  print -r -- ""
  print -r -- "opening ${label}..."
  command "${pager_cmd[@]}" "$target"
  _copilot_zle_restore_tty_state "$tty_state"
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
  local tty_state
  tty_state="$(_copilot_zle_capture_tty_state)"

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
  print -r -- "  Ctrl+X ]/[    cycle AI candidates"
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
  if ! read -rk 1 -t 30 choice 2>/dev/null; then
    choice="q"
  fi
  print -r -- ""
  _copilot_zle_restore_tty_state "$tty_state"

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
    _copilot_zle_daemon_read_state
    local payload request
    payload="$(jq -n -c --arg command "$command" --argjson exitCode "${exit_code:-0}" '{ command: $command, exitCode: $exitCode }' 2>/dev/null)"
    request="$(_copilot_zle_build_request "mark_executed" "" "$payload" 2>/dev/null)"
    [[ -n "$request" ]] || return
    {
      _copilot_zle_daemon_connect 2>/dev/null && {
        print -r -u "$REPLY" -- "$request"
        ztcp -c "$REPLY" 2>/dev/null
      }
    } 2>/dev/null
  else
    # Fallback: call Node directly (lightweight, fire-and-forget)
    local helpers_dir
    helpers_dir="$(_copilot_zle_helpers_dir)"
    NODE_NO_WARNINGS=1 node -e "
      import { markExecuted } from '${helpers_dir}/lib/flight-log.mjs';
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

  NODE_NO_WARNINGS=1 node "$helpers_dir/lib/copilot-daemon.mjs" --tcp \
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
    _copilot_zle_daemon_read_state
    _copilot_zle_debug_log "daemon reconnected: pid=$_COPILOT_ZLE_DAEMON_PID port=$_COPILOT_ZLE_DAEMON_PORT"
    return 0
  fi

  _copilot_zle_debug_log "daemon not running, starting..."
  _copilot_zle_daemon_start
}

_copilot_zle_daemon_connect() {
  zmodload -e zsh/net/tcp || zmodload zsh/net/tcp 2>/dev/null || return 1

  local attempt=0
  while (( attempt < 2 )); do
    [[ "$_COPILOT_ZLE_CFG_DAEMON_ENABLED" == "true" ]] || return 1
    if (( _COPILOT_ZLE_DAEMON_PORT == 0 )); then
      _copilot_zle_daemon_read_state
    fi
    ztcp 127.0.0.1 "$_COPILOT_ZLE_DAEMON_PORT" 2>/dev/null && return 0
    _copilot_zle_daemon_read_state
    (( attempt++ ))
  done

  return 1
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
  local error_code="" error_json="" command_json="" rest="" command=""

  if [[ -z "$2" || "$2" == "hup" ]]; then
    read -r -u $fd error_code 2>/dev/null
    read -r -u $fd error_json 2>/dev/null
    read -r -u $fd command_json 2>/dev/null
    IFS='' read -rd '' -u $fd rest 2>/dev/null
    command="$(_copilot_zle_json_get "$command_json" '.' 2>/dev/null)"
    _copilot_zle_debug_log "suggest result: '$command' ec='$error_code'"

    # Only show if buffer is still empty (user hasn't started typing)
    if [[ -z "$BUFFER" && -n "$command" ]]; then
      _copilot_zle_ghost_render "$command"
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

  _copilot_zle_debug_log "suggest: requesting for '$_COPILOT_ZLE_LAST_EXECUTED_COMMAND' (exit $_COPILOT_ZLE_LAST_EXIT_CODE)"
  if [[ "$_COPILOT_ZLE_LAST_EXIT_CODE" != "0" ]]; then
    _copilot_zle_fix_message "$(_copilot_zle_failure_notice_message suggest "$_COPILOT_ZLE_LAST_EXIT_CODE")"
  fi

  # Cancel any in-flight suggest
  if [[ -n "$_COPILOT_ZLE_GHOST_FD" ]]; then
    ztcp -c "$_COPILOT_ZLE_GHOST_FD" 2>/dev/null
    zle -F "$_COPILOT_ZLE_GHOST_FD" 2>/dev/null
    _COPILOT_ZLE_GHOST_FD=""
  fi

  _copilot_zle_daemon_connect 2>/dev/null || return
  local tcp_fd=$REPLY

  local history_snippet=""
  if whence -w fc >/dev/null 2>&1; then
    history_snippet="$(fc -l -5 2>/dev/null | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//' || echo "")"
  fi

  local payload request
  payload="$(jq -n -c \
    --arg lastCommand "$_COPILOT_ZLE_LAST_EXECUTED_COMMAND" \
    --argjson exitCode "${_COPILOT_ZLE_LAST_EXIT_CODE:-0}" \
    --arg cwd "$PWD" \
    --arg home "$HOME" \
    --arg recentHistory "$history_snippet" \
    --arg model "$(_copilot_zle_effective_model)" \
    '{
      lastCommand: $lastCommand,
      exitCode: $exitCode,
      cwd: $cwd,
      home: $home,
      recentHistory: $recentHistory,
      model: $model
    }' 2>/dev/null)"
  request="$(_copilot_zle_build_request "suggest" "zle" "$payload" 2>/dev/null)"
  [[ -n "$request" ]] || {
    ztcp -c "$tcp_fd" 2>/dev/null
    return
  }

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
# Shared shell heuristics live in shell/nl-detection.zsh.
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
bindkey '^X]' _copilot_zle_cycle_next 2>/dev/null || true    # Ctrl+X ]
bindkey '^X[' _copilot_zle_cycle_prev 2>/dev/null || true    # Ctrl+X [

# ── Proactive Autofix ────────────────────────────────────────────────
_copilot_zle_autofix_precmd() {
  [[ "$_COPILOT_ZLE_CFG_AUTOFIX_ENABLED" == "true" ]] || return
  # Only trigger on non-zero exit
  [[ "$_COPILOT_ZLE_LAST_EXIT_CODE" != "0" ]] || return
  [[ -n "$_COPILOT_ZLE_LAST_EXECUTED_COMMAND" ]] || return

  _copilot_zle_debug_log "autofix: command='$_COPILOT_ZLE_LAST_EXECUTED_COMMAND' exit=$_COPILOT_ZLE_LAST_EXIT_CODE"

  # Need daemon for autofix
  _copilot_zle_daemon_ensure 2>/dev/null || return

  _copilot_zle_fix_message "$(_copilot_zle_failure_notice_message autofix "$_COPILOT_ZLE_LAST_EXIT_CODE")"

  _copilot_zle_daemon_connect 2>/dev/null || return
  local tcp_fd=$REPLY

  local payload request
  payload="$(_copilot_zle_build_payload "fix the last command that failed" "fix")"
  request="$(_copilot_zle_build_request "generate" "zle" "$payload" 2>/dev/null)"
  [[ -n "$request" ]] || {
    ztcp -c "$tcp_fd" 2>/dev/null
    return
  }

  print -r -u "$tcp_fd" -- "$request"

  _COPILOT_ZLE_USING_DAEMON=1
  zle -F "$tcp_fd" _copilot_zle_autofix_result_handler
}

_copilot_zle_autofix_result_handler() {
  local fd=$1

  if [[ -z "$2" || "$2" == "hup" ]]; then
    local ec="" err_json="" cmd_json="" rest="" err="" cmd=""
    read -r -u $fd ec 2>/dev/null
    read -r -u $fd err_json 2>/dev/null
    read -r -u $fd cmd_json 2>/dev/null
    IFS='' read -rd '' -u $fd rest 2>/dev/null
    err="$(_copilot_zle_json_get "$err_json" '.' 2>/dev/null)"
    cmd="$(_copilot_zle_json_get "$cmd_json" '.' 2>/dev/null)"

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

  local history_count="${_COPILOT_ZLE_CFG_CONTEXT_HISTORY_COUNT:-5}"
  local include_git="${_COPILOT_ZLE_CFG_CONTEXT_INCLUDE_GIT:-true}"
  local include_failure="${_COPILOT_ZLE_CFG_CONTEXT_INCLUDE_FAILURE:-true}"

  local recent_history=""
  if (( history_count > 0 )); then
    if (( $+commands[fc] )) || whence -w fc >/dev/null 2>&1; then
      recent_history="$(fc -l -${history_count} 2>/dev/null | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//' || echo "")"
    fi
  fi

  if [[ "$_COPILOT_ZLE_LAST_GIT_CWD" != "$PWD" ]]; then
    _copilot_zle_refresh_shell_context
  fi

  local git_summary="$_COPILOT_ZLE_LAST_GIT_SUMMARY"

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
  local in_git_repo="$_COPILOT_ZLE_LAST_GIT_IN_REPO"

  # Gather key aliases once per cwd refresh instead of every request.
  local alias_context="$_COPILOT_ZLE_LAST_ALIAS_CONTEXT"

  jq -n -c \
    --arg prompt "$prompt" \
    --arg mode "$mode" \
    --arg model "$(_copilot_zle_effective_model)" \
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
      model: $model,
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
  if [[ ! -x "$(command -v node)" ]]; then
    _copilot_zle_error_message "Node not found."
    return 1
  fi

  local helpers_dir
  helpers_dir="$(_copilot_zle_helpers_dir)"
  if [[ ! -f "$helpers_dir/lib/copilot-helper.mjs" ]]; then
    _copilot_zle_error_message "${_COPILOT_ZLE_CFG_BRAND_PRODUCT_NAME} helper missing."
    return 1
  fi
  if [[ ! -d "$helpers_dir/node_modules/@github/copilot-sdk" ]]; then
    _copilot_zle_error_message "GitHub Copilot SDK not installed. Run npm ci in the plugin directory."
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

_copilot_zle_daemon_prewarm() {
  return
}

# ── Async Spinner Handler (SAM-45) ──────────────────────────────────
_copilot_zle_spinner_handler() {
  local fd="$1"
  local line=""
  if [[ -n "$_COPILOT_ZLE_RESULT_FILE" && -s "$_COPILOT_ZLE_RESULT_FILE" ]]; then
    local result_fd
    builtin exec {result_fd}<"$_COPILOT_ZLE_RESULT_FILE"
    _COPILOT_ZLE_RESULT_FD="$result_fd"
    rm -f "$_COPILOT_ZLE_RESULT_FILE" 2>/dev/null || true
    _COPILOT_ZLE_RESULT_FILE=""
    _COPILOT_ZLE_RESULT_PID=""
    _copilot_zle_result_handler "$result_fd" "hup"
    return
  fi
  if ! read -r -u "$fd" line 2>/dev/null; then
    # Spinner process ended (SIGPIPE from fd close or natural exit)
    zle -F "$fd" 2>/dev/null
    builtin exec {fd}<&- 2>/dev/null
    _COPILOT_ZLE_SPINNER_FD=""
    return
  fi
  if (( _COPILOT_ZLE_ASYNC_ACTIVE )); then
    _COPILOT_ZLE_SPINNER_IDX=$(( (_COPILOT_ZLE_SPINNER_IDX % ${#_COPILOT_ZLE_SPINNER_FRAMES[@]}) + 1 ))
    _copilot_zle_refresh_live_rprompt
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
  local error_json="" command_json="" candidate_blob=""

  # Stop spinner
  _COPILOT_ZLE_ASYNC_ACTIVE=0
  if [[ -n "$_COPILOT_ZLE_SPINNER_FD" ]]; then
    zle -F "$_COPILOT_ZLE_SPINNER_FD" 2>/dev/null
    builtin exec {_COPILOT_ZLE_SPINNER_FD}<&- 2>/dev/null
    _COPILOT_ZLE_SPINNER_FD=""
  fi

  if [[ -z "$2" || "$2" == "hup" ]]; then
    # Format: line 1 = error_code, line 2 = error, line 3 = command,
    # line 4 = candidate blob (US-delimited).
    read -r -u $fd _COPILOT_ZLE_PENDING_EC 2>/dev/null
    read -r -u $fd error_json 2>/dev/null
    read -r -u $fd command_json 2>/dev/null
    IFS='' read -rd '' -u $fd candidate_blob 2>/dev/null
    _COPILOT_ZLE_PENDING_ERR="$(_copilot_zle_json_get "$error_json" '.' 2>/dev/null)"
    _COPILOT_ZLE_PENDING_CMD="$(_copilot_zle_json_get "$command_json" '.' 2>/dev/null)"
    _COPILOT_ZLE_PENDING_RAW="$(_copilot_zle_json_get "$candidate_blob" '.' 2>/dev/null)"

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
  _COPILOT_ZLE_RESULT_PID=""
  if [[ -n "$_COPILOT_ZLE_RESULT_FILE" ]]; then
    rm -f "$_COPILOT_ZLE_RESULT_FILE" 2>/dev/null || true
    _COPILOT_ZLE_RESULT_FILE=""
  fi
}

# ── Apply Result Widget ─────────────────────────────────────────────
# Registered as a ZLE widget so BUFFER modifications persist (the correct
# async pattern, matching zsh-autosuggestions).
_copilot_zle_apply_result() {
  local command="$_COPILOT_ZLE_PENDING_CMD"
  local error="$_COPILOT_ZLE_PENDING_ERR"
  local error_code="$_COPILOT_ZLE_PENDING_EC"
  local candidate_blob="$_COPILOT_ZLE_PENDING_RAW"
  local mode="$_COPILOT_ZLE_ASYNC_MODE"
  local latency_ms=""

  # Results can arrive through multiple transports; make post-apply cleanup
  # idempotent so the next Ctrl+G always starts a fresh request.
  _COPILOT_ZLE_ASYNC_ACTIVE=0
  if [[ -n "$_COPILOT_ZLE_RESULT_FD" ]]; then
    zle -F "$_COPILOT_ZLE_RESULT_FD" 2>/dev/null
    if (( _COPILOT_ZLE_USING_DAEMON )); then
      ztcp -c "$_COPILOT_ZLE_RESULT_FD" 2>/dev/null
    else
      builtin exec {_COPILOT_ZLE_RESULT_FD}<&- 2>/dev/null
    fi
    _COPILOT_ZLE_RESULT_FD=""
  fi
  if [[ -n "$_COPILOT_ZLE_SPINNER_FD" ]]; then
    zle -F "$_COPILOT_ZLE_SPINNER_FD" 2>/dev/null
    builtin exec {_COPILOT_ZLE_SPINNER_FD}<&- 2>/dev/null
    _COPILOT_ZLE_SPINNER_FD=""
  fi
  if [[ -n "$_COPILOT_ZLE_RESULT_PID" ]]; then
    kill "$_COPILOT_ZLE_RESULT_PID" 2>/dev/null || true
    _COPILOT_ZLE_RESULT_PID=""
  fi
  if [[ -n "$_COPILOT_ZLE_RESULT_FILE" ]]; then
    rm -f "$_COPILOT_ZLE_RESULT_FILE" 2>/dev/null || true
    _COPILOT_ZLE_RESULT_FILE=""
  fi

  _COPILOT_ZLE_PENDING_CMD=""
  _COPILOT_ZLE_PENDING_ERR=""
  _COPILOT_ZLE_PENDING_EC=""
  _COPILOT_ZLE_PENDING_RAW=""

  if (( _COPILOT_ZLE_REQUEST_STARTED_AT > 0 )); then
    latency_ms="$(( $(_copilot_zle_now_ms) - _COPILOT_ZLE_REQUEST_STARTED_AT ))ms"
  fi
  _COPILOT_ZLE_REQUEST_STARTED_AT=0

  _copilot_zle_debug_log "apply_result widget: cmd_len=${#command} ec='$error_code' mode=$mode"

  if [[ -z "$command" ]]; then
    _copilot_zle_set_prompt_state "$(_copilot_zle_mode_label "$mode")" "" "$latency_ms"
    case "$error_code" in
      copilot_cli_missing)
        _copilot_zle_error_message "Required CLI dependency missing."
        ;;
      copilot_auth_required)
        _copilot_zle_error_message "GitHub Copilot auth required."
        ;;
      copilot_model_rejected)
        _copilot_zle_error_message "Model rejected: $(_copilot_zle_effective_model)"
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
  local -a _copilot_words
  _copilot_words=( ${(z)command} )
  local _copilot_idx=1
  while (( _copilot_idx <= ${#_copilot_words} )); do
    if [[ "${_copilot_words[_copilot_idx]}" == [A-Za-z_][A-Za-z0-9_]*=* ]]; then
      (( _copilot_idx++ ))
      continue
    fi
    break
  done
  local _copilot_first_token="${_copilot_words[_copilot_idx]:-}"
  if [[ "$_copilot_first_token" == "command" ]]; then
    (( _copilot_idx++ ))
    _copilot_first_token="${_copilot_words[_copilot_idx]:-}"
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

  local -a _copilot_candidates=()
  local -A _copilot_seen=()
  local _copilot_candidate
  for _copilot_candidate in "${(@s:$'\x1f':)candidate_blob}" "$command"; do
    [[ -n "$_copilot_candidate" ]] || continue
    [[ -n "${_copilot_seen[$_copilot_candidate]:-}" ]] && continue
    _copilot_seen[$_copilot_candidate]=1
    _copilot_candidates+=("$_copilot_candidate")
  done
  (( ${#_copilot_candidates[@]} > 0 )) || _copilot_candidates=("$command")
  _COPILOT_ZLE_CANDIDATES=("${_copilot_candidates[@]}")
  _COPILOT_ZLE_CANDIDATE_IDX=1

  _copilot_zle_debug_log "BUFFER set: len=${#BUFFER}"

  local _copilot_risk
  _copilot_risk="$(_copilot_zle_command_risk "$command")"
  _copilot_zle_set_prompt_state "$(_copilot_zle_mode_label "$mode")" "$_copilot_risk" "$latency_ms"

  # Apply visual highlight using cached config (SAM-42/44)
  if [[ "$_COPILOT_ZLE_CFG_HIGHLIGHT_ENABLED" == "true" && "$_COPILOT_ZLE_CFG_HIGHLIGHT_STYLE" != "none" ]]; then
    _COPILOT_ZLE_GENERATED_BUFFER="$BUFFER"
    region_highlight=("0 ${#BUFFER} ${_COPILOT_ZLE_CFG_HIGHLIGHT_STYLE}")
  fi

  case "$mode" in
    fix)
        _copilot_zle_status_message "FIX APPLIED. REVIEW BEFORE EXECUTION.${_copilot_dry_warn}${_copilot_risk:+ [$_copilot_risk]}${latency_ms:+ [$latency_ms]}"
      ;;
    refine)
      _copilot_zle_status_message "COMMAND REFINED. REVIEW BEFORE EXECUTION.${_copilot_dry_warn}${_copilot_risk:+ [$_copilot_risk]}${latency_ms:+ [$latency_ms]}"
      ;;
    chain)
      _copilot_zle_status_message "PIPELINE EXTENDED. REVIEW BEFORE EXECUTION.${_copilot_dry_warn}${_copilot_risk:+ [$_copilot_risk]}${latency_ms:+ [$latency_ms]}"
      ;;
    *)
      _copilot_zle_status_message "COMMAND RECEIVED. REVIEW BEFORE EXECUTION.${_copilot_dry_warn}${_copilot_risk:+ [$_copilot_risk]}${latency_ms:+ [$latency_ms]}"
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
  if [[ -n "$_COPILOT_ZLE_RESULT_PID" ]]; then
    kill "$_COPILOT_ZLE_RESULT_PID" 2>/dev/null || true
    _COPILOT_ZLE_RESULT_PID=""
  fi
  if [[ -n "$_COPILOT_ZLE_RESULT_FILE" ]]; then
    rm -f "$_COPILOT_ZLE_RESULT_FILE" 2>/dev/null || true
    _COPILOT_ZLE_RESULT_FILE=""
  fi
  _copilot_zle_status_message "REQUEST CANCELLED."
  zle -R
}

# ── Daemon Request Path ──────────────────────────────────────────────
_copilot_zle_send_via_daemon() {
  local payload="$1" mode="$2"

  _copilot_zle_daemon_connect 2>/dev/null || return 1
  local tcp_fd=$REPLY
  _COPILOT_ZLE_USING_DAEMON=1

  local request
  request="$(_copilot_zle_build_request "generate" "zle" "$payload" 2>/dev/null)"
  [[ -n "$request" ]] || {
    ztcp -c "$tcp_fd" 2>/dev/null
    return 1
  }
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
  local helper="$helpers_dir/lib/copilot-helper.mjs"

  _COPILOT_ZLE_USING_DAEMON=0

  local stderr_target="/dev/null"
  if [[ -n "${COPILOT_ZLE_DEBUG:-}" ]]; then
    stderr_target="$COPILOT_ZLE_DEBUG_LOG"
  fi
  local result_file
  result_file="$(mktemp "${TMPDIR:-/tmp}/copilot-zle-result.XXXXXX")" || return 1
  _COPILOT_ZLE_RESULT_FILE="$result_file"

  (
    local raw ec err cmd candidates
    raw="$(printf '%s' "$payload" | COPILOT_ZLE_DEBUG="${COPILOT_ZLE_DEBUG:-}" NODE_NO_WARNINGS=1 node "$helper" 2>>"$stderr_target")"
    ec="$(printf '%s' "$raw" | jq -r '.error_code // empty' 2>/dev/null)"
    err="$(printf '%s' "$raw" | jq -c '.error // ""' 2>/dev/null)"
    cmd="$(printf '%s' "$raw" | jq -c '.command // ""' 2>/dev/null)"
    candidates="$(printf '%s' "$raw" | jq -c '(.candidates // []) | map(select(type == "string" and length > 0)) | join("\u001f")' 2>/dev/null)"
    {
      printf '%s\n' "$ec"
      printf '%s\n' "$err"
      printf '%s\n' "$cmd"
      printf '%s' "$candidates"
    } >| "$result_file"
  ) &!
  _COPILOT_ZLE_RESULT_PID=$!

  _copilot_zle_debug_log "subprocess result pid=$_COPILOT_ZLE_RESULT_PID file=$_COPILOT_ZLE_RESULT_FILE launched"
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

  if [[ -z "${_COPILOT_ZLE_RPROMPT_BASE+x}" ]]; then
    typeset -g _COPILOT_ZLE_RPROMPT_BASE="$RPROMPT"
  fi

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
        if _copilot_zle_should_handoff_to_opencode "$effective_prompt"; then
          _COPILOT_ZLE_LAST_HANDOFF_PROMPT="$effective_prompt"
          _copilot_zle_set_prompt_state "OC" "" ""
          _copilot_zle_fix_message "Larger workflow detected. Press Ctrl+X O to open in opencode."
          zle -R
          return
        fi
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

  # Launch async (restored committed behavior with runtime fixes kept)
  _COPILOT_ZLE_ASYNC_MODE="$mode"
  _COPILOT_ZLE_ASYNC_ACTIVE=1
  _COPILOT_ZLE_SPINNER_IDX=0
  _COPILOT_ZLE_REQUEST_STARTED_AT="$(_copilot_zle_now_ms)"
  _copilot_zle_set_prompt_state "$(_copilot_zle_mode_label "$mode")" "" "..."

  builtin exec {_COPILOT_ZLE_SPINNER_FD}< <(
    while true; do
      sleep 0.3
      printf 'tick\n'
    done
  )
  zle -F "$_COPILOT_ZLE_SPINNER_FD" _copilot_zle_spinner_handler

  _copilot_zle_debug_log "spinner fd=$_COPILOT_ZLE_SPINNER_FD"

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
    local error_code="" explanation_json="" skip="" rest="" explanation=""
    read -r -u $fd error_code 2>/dev/null
    read -r -u $fd explanation_json 2>/dev/null
    read -r -u $fd skip 2>/dev/null
    IFS='' read -rd '' -u $fd rest 2>/dev/null
    explanation="$(_copilot_zle_json_get "$explanation_json" '.' 2>/dev/null)"

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

  _copilot_zle_daemon_connect 2>/dev/null || {
    _copilot_zle_explain_message "Daemon connection failed."
    return
  }
  local tcp_fd=$REPLY

  local payload request
  payload="$(jq -n -c \
    --arg command "$command" \
    --arg cwd "$PWD" \
    --arg home "$HOME" \
    --arg model "$(_copilot_zle_effective_model)" \
    '{ command: $command, cwd: $cwd, home: $home, model: $model }' 2>/dev/null)"
  request="$(_copilot_zle_build_request "explain" "zle" "$payload" 2>/dev/null)"
  [[ -n "$request" ]] || {
    ztcp -c "$tcp_fd" 2>/dev/null
    _copilot_zle_explain_message "Explain request build failed."
    return
  }
  print -r -u "$tcp_fd" -- "$request"

  _COPILOT_ZLE_USING_DAEMON=1
  zle -F "$tcp_fd" _copilot_zle_explain_result_handler
}

# ── Key Bindings ─────────────────────────────────────────────────────
if [[ -z "${_COPILOT_ZLE_WIDGETS_REGISTERED:-}" ]]; then
  zle -N copilot_zle_generate
  zle -N copilot_zle_explain
  zle -N copilot_zle_help
  zle -N copilot_zle_handoff_opencode
  bindkey '^g' copilot_zle_generate
  bindkey '^e' copilot_zle_explain
  bindkey '^Xo' copilot_zle_handoff_opencode 2>/dev/null || true
  bindkey '^XO' copilot_zle_handoff_opencode 2>/dev/null || true
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
  bindkey -M viins '^Xo' copilot_zle_handoff_opencode 2>/dev/null || true
  bindkey -M vicmd '^Xo' copilot_zle_handoff_opencode 2>/dev/null || true
  bindkey -M viins '^XO' copilot_zle_handoff_opencode 2>/dev/null || true
  bindkey -M vicmd '^XO' copilot_zle_handoff_opencode 2>/dev/null || true
  bindkey '^[OC' _copilot_zle_ghost_accept_full 2>/dev/null || true
  bindkey '^[[C' _copilot_zle_ghost_accept_full 2>/dev/null || true
  bindkey '^F' _copilot_zle_ghost_accept_full 2>/dev/null || true
  bindkey '^[[1;5C' _copilot_zle_ghost_accept_word 2>/dev/null || true
  typeset -g _COPILOT_ZLE_WIDGETS_REGISTERED=1
fi
