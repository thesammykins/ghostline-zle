# Shared pending-message state so prompt-time notices can be queued until ZLE is active.

typeset -g _COPILOT_ZLE_PENDING_MESSAGE_PREFIX="${_COPILOT_ZLE_PENDING_MESSAGE_PREFIX:-}"
typeset -g _COPILOT_ZLE_PENDING_MESSAGE_BODY="${_COPILOT_ZLE_PENDING_MESSAGE_BODY:-}"

_copilot_zle_set_pending_message() {
  _COPILOT_ZLE_PENDING_MESSAGE_PREFIX="$1"
  _COPILOT_ZLE_PENDING_MESSAGE_BODY="$2"
}

_copilot_zle_take_pending_message() {
  local prefix="$_COPILOT_ZLE_PENDING_MESSAGE_PREFIX"
  local body="$_COPILOT_ZLE_PENDING_MESSAGE_BODY"

  _COPILOT_ZLE_PENDING_MESSAGE_PREFIX=""
  _COPILOT_ZLE_PENDING_MESSAGE_BODY=""

  [[ -n "$prefix" ]] || return 1

  if [[ -n "$body" ]]; then
    print -r -- "$prefix $body"
    return 0
  fi

  print -r -- "$prefix"
}
