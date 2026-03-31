# ghostline-zle.zsh
# Public-facing entrypoint for the copilot-zle core.

typeset -g GHOSTLINE_ZLE_PLUGIN_PATH="${GHOSTLINE_ZLE_PLUGIN_PATH:-${(%):-%x}}"
typeset -g _GHOSTLINE_ZLE_DIR="${GHOSTLINE_ZLE_PLUGIN_PATH:A:h}"

export COPILOT_ZLE_ROOT_DIR="${COPILOT_ZLE_ROOT_DIR:-${_GHOSTLINE_ZLE_DIR}}"
export COPILOT_ZLE_PLUGIN_PATH="${COPILOT_ZLE_PLUGIN_PATH:-${_GHOSTLINE_ZLE_DIR}/copilot-zle.zsh}"
export COPILOT_ZLE_CONFIG_FILE="${COPILOT_ZLE_CONFIG_FILE:-${COPILOT_ZLE_ROOT_DIR}/config.json}"

if [[ ! -f "${_GHOSTLINE_ZLE_DIR}/copilot-zle.zsh" ]]; then
  print -u2 -- "ghostline-zle: missing core plugin at ${_GHOSTLINE_ZLE_DIR}/copilot-zle.zsh"
  return 1
fi

source "${_GHOSTLINE_ZLE_DIR}/copilot-zle.zsh"
