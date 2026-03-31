# Shared helpers for visible failure notices around suggest/autofix flows.

_copilot_zle_failure_notice_message() {
  local context="$1"
  local exit_code="$2"
  local action_text=""

  case "$context" in
    suggest)
      action_text="SUGGESTING NEXT STEP..."
      ;;
    autofix)
      action_text="PREPARING FIX..."
      ;;
    *)
      action_text="ANALYZING FAILURE..."
      ;;
  esac

  if [[ -n "$exit_code" && "$exit_code" != "0" ]]; then
    printf 'FAIL DETECTED (exit %s). %s' "$exit_code" "$action_text"
    return
  fi

  printf 'FAIL DETECTED. %s' "$action_text"
}
