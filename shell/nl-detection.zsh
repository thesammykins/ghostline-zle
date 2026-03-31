# Shared NL detection helpers for the Ghostline shell core and tests.

_copilot_zle_nl_is_assignment_token() {
  local token="$1"
  [[ "$token" == [A-Za-z_][A-Za-z0-9_]*=* ]]
}

_copilot_zle_is_natural_language() {
  local input="$1"
  [[ -n "$input" ]] || return 1

  local -a words=( ${(z)input} )
  (( ${#words} >= _COPILOT_ZLE_CFG_NL_MIN_WORDS )) || return 1

  local first_word=""
  local token=""
  local saw_assignment=0

  for token in "${words[@]}"; do
    if _copilot_zle_nl_is_assignment_token "$token"; then
      saw_assignment=1
      continue
    fi
    first_word="$token"
    break
  done

  if (( saw_assignment )); then
    return 1
  fi

  [[ -n "$first_word" ]] || return 1

  case "$first_word" in
    /*|~*|./*|../*|'$'*|'!'*|'#'*) return 1 ;;
  esac

  if (( $+commands[$first_word] )) || \
     (( $+aliases[$first_word] )) || \
     (( $+functions[$first_word] )) || \
     whence -w "$first_word" >/dev/null 2>&1; then
    return 1
  fi

  return 0
}
