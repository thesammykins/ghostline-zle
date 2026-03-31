#!/usr/bin/env zsh
emulate -L zsh
setopt err_return pipe_fail no_unset

source "${0:A:h}/../shell/nl-detection.zsh"

typeset -g _COPILOT_ZLE_CFG_NL_MIN_WORDS=3

assert_natural_language() {
  local input="$1"
  if ! _copilot_zle_is_natural_language "$input"; then
    print -u2 -- "expected natural language: $input"
    exit 1
  fi
}

assert_shell_command() {
  local input="$1"
  if _copilot_zle_is_natural_language "$input"; then
    print -u2 -- "expected shell command: $input"
    exit 1
  fi
}

assert_natural_language "show me large files"
assert_shell_command 'MOTD_FORCE=1 bash "scripts/motd.sh"'
assert_shell_command 'FOO=bar BAR=baz BAZ=qux'
assert_shell_command "./scripts/motd.sh"
assert_shell_command "rg TODO README.md"

print -- "nl-detection tests passed"
