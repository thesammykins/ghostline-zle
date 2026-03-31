#!/usr/bin/env zsh
emulate -L zsh
setopt err_return pipe_fail no_unset

source "${0:A:h}/../shell/failure-indicator.zsh"

assert_eq() {
  local actual="$1"
  local expected="$2"
  if [[ "$actual" != "$expected" ]]; then
    print -u2 -- "expected: $expected"
    print -u2 -- "actual:   $actual"
    exit 1
  fi
}

assert_eq \
  "$(_copilot_zle_failure_notice_message suggest 1)" \
  "FAIL DETECTED (exit 1). SUGGESTING NEXT STEP..."

assert_eq \
  "$(_copilot_zle_failure_notice_message autofix 127)" \
  "FAIL DETECTED (exit 127). PREPARING FIX..."

assert_eq \
  "$(_copilot_zle_failure_notice_message unknown 0)" \
  "FAIL DETECTED. ANALYZING FAILURE..."

print -- "failure-indicator tests passed"
