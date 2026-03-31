#!/usr/bin/env zsh
emulate -L zsh
setopt err_return pipe_fail no_unset

source "${0:A:h}/../shell/message-queue.zsh"

assert_eq() {
  local actual="$1"
  local expected="$2"
  if [[ "$actual" != "$expected" ]]; then
    print -u2 -- "expected: $expected"
    print -u2 -- "actual:   $actual"
    exit 1
  fi
}

_copilot_zle_set_pending_message "[GHOSTLINE FIX]" "FAIL DETECTED (exit 1). SUGGESTING NEXT STEP..."
local tmpfile
tmpfile="$(mktemp)"
_copilot_zle_take_pending_message >"$tmpfile"
assert_eq \
  "$(cat "$tmpfile")" \
  "[GHOSTLINE FIX] FAIL DETECTED (exit 1). SUGGESTING NEXT STEP..."
rm -f "$tmpfile"

if _copilot_zle_take_pending_message >/dev/null 2>&1; then
  print -u2 -- "pending message should clear after being read"
  exit 1
fi

print -- "message-queue tests passed"
