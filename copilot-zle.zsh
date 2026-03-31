# copilot-zle.zsh
# Compatibility entrypoint that forwards to the internal shell core.

typeset -g _COPILOT_ZLE_ENTRYPOINT="${COPILOT_ZLE_PLUGIN_PATH:-${(%):-%x}}"
typeset -g _COPILOT_ZLE_DIR="${_COPILOT_ZLE_ENTRYPOINT:A:h}"

export COPILOT_ZLE_ROOT_DIR="${COPILOT_ZLE_ROOT_DIR:-${_COPILOT_ZLE_DIR}}"
export COPILOT_ZLE_PLUGIN_PATH="${COPILOT_ZLE_PLUGIN_PATH:-${_COPILOT_ZLE_DIR}/copilot-zle.zsh}"
export COPILOT_ZLE_CONFIG_FILE="${COPILOT_ZLE_CONFIG_FILE:-${COPILOT_ZLE_ROOT_DIR}/config.json}"

if [[ ! -f "${COPILOT_ZLE_ROOT_DIR}/shell/copilot-zle-core.zsh" ]]; then
  print -u2 -- "copilot-zle: missing shell core at ${COPILOT_ZLE_ROOT_DIR}/shell/copilot-zle-core.zsh"
  return 1
fi

source "${COPILOT_ZLE_ROOT_DIR}/shell/copilot-zle-core.zsh"
