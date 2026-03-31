#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZSHRC_PATH="${ZDOTDIR:-$HOME}/.zshrc"
WRITE_ZSHRC=0
SKIP_NPM=0

usage() {
  cat <<'EOF'
Usage: ./scripts/install.sh [--write-zshrc] [--skip-npm] [--print-snippet]

Options:
  --write-zshrc   Append a Ghostty-only source block to ~/.zshrc (or $ZDOTDIR/.zshrc).
  --skip-npm      Skip running npm ci. Useful for tests or already-installed repos.
  --print-snippet Print the source block after validation (default behavior).
  --help          Show this help text.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --write-zshrc) WRITE_ZSHRC=1 ;;
    --skip-npm|--print-snippet) ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "ghostline install: unknown option: $arg" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "ghostline install: missing required command: $name" >&2
    exit 1
  fi
}

require_command node
require_command npm
require_command jq

NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
if [[ "$NODE_MAJOR" -lt 20 ]]; then
  echo "ghostline install: Node 20+ is required." >&2
  exit 1
fi

if [[ "${*:-}" != *"--skip-npm"* ]]; then
  echo "Installing Node dependencies with npm ci..."
  (
    cd "$ROOT_DIR"
    npm ci
  )
fi

BLOCK_START="# >>> ghostline-zle (ghostty) >>>"
BLOCK_END="# <<< ghostline-zle (ghostty) <<<"
SNIPPET="$(cat <<EOF
$BLOCK_START
if [[ -n "\${GHOSTTY_RESOURCES_DIR:-}" || "\${TERM_PROGRAM:-}" == "ghostty" ]]; then
  source "$ROOT_DIR/ghostline-zle.zsh"
fi
$BLOCK_END
EOF
)"

if [[ "$WRITE_ZSHRC" -eq 1 ]]; then
  mkdir -p "$(dirname "$ZSHRC_PATH")"
  touch "$ZSHRC_PATH"
  if grep -Fq "$BLOCK_START" "$ZSHRC_PATH"; then
    echo "Ghostty source block already present in $ZSHRC_PATH"
  else
    printf '\n%s\n' "$SNIPPET" >> "$ZSHRC_PATH"
    echo "Added Ghostty source block to $ZSHRC_PATH"
  fi
fi

echo
echo "Ghostty source block:"
printf '%s\n' "$SNIPPET"
echo
if [[ "$WRITE_ZSHRC" -eq 0 ]]; then
  echo "Run ./scripts/install.sh --write-zshrc to append it automatically."
fi
echo "Restart your shell or run: exec zsh"
