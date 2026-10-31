#!/usr/bin/env bats
# Pruebas del selector básico (sin fzf) y del registro usado por la TUI.

load helpers/common

setup() {
  gcpctl_setup
  export GCPCTL_PICKER=basic
  source "${REPO_ROOT}/lib/core.sh"
  source "${REPO_ROOT}/ui/picker.sh"
}

@test "picker::choose devuelve el valor por número" {
  run picker::choose "p" "h" $'uno\tUno' $'dos\tDos' <<<"2"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dos" ]]
}

@test "picker::choose filtra por texto" {
  result="$(picker::choose "p" "h" alpha beta gamma 2>/dev/null <<<$'gam\n1')"
  [ "$result" = "gamma" ]
}

@test "picker::choose con 0 vuelve con código 130" {
  run picker::choose "p" "h" a b <<<"0"
  [ "$status" -eq 130 ]
}

@test "picker::confirm acepta 's'" {
  run picker::confirm "¿ok?" <<<"s"
  [ "$status" -eq 0 ]
  run picker::confirm "¿ok?" <<<""
  [ "$status" -eq 1 ]
}

@test "picker::input usa el valor por defecto" {
  result="$(picker::input "x" "def" 2>/dev/null <<<"")"
  [ "$result" = "def" ]
}

@test "menu: los tipos de argumento declarados tienen selector" {
  source "${REPO_ROOT}/lib/registry.sh"
  for f in "${REPO_ROOT}"/lib/*.sh; do
    case "$f" in */core.sh | */registry.sh) continue ;; esac
    source "$f"
  done
  source "${REPO_ROOT}/ui/menu.sh"
  local key kind
  for key in "${!REG_ARGS[@]}"; do
    menu::_split_kinds "${REG_ARGS[$key]}"
    for kind in "${MENU_KINDS[@]}"; do
      kind="${kind%\?}"
      [[ "$kind" == text:* ]] && continue
      declare -F "menu::ask_${kind}" >/dev/null || {
        echo "Falta menu::ask_${kind} (${key})"
        return 1
      }
    done
  done
}

@test "menu: _split_kinds separa etiquetas de texto con espacios" {
  source "${REPO_ROOT}/lib/registry.sh"
  source "${REPO_ROOT}/ui/menu.sh"
  menu::_split_kinds "text:Propiedad (p. ej. x) text:Valor"
  [ "${#MENU_KINDS[@]}" -eq 2 ]
  [ "${MENU_KINDS[0]}" = "text:Propiedad (p. ej. x)" ]
  [ "${MENU_KINDS[1]}" = "text:Valor" ]
}

@test "menu: todas las acciones registradas están implementadas" {
  source "${REPO_ROOT}/lib/registry.sh"
  for f in "${REPO_ROOT}"/lib/*.sh; do
    case "$f" in */core.sh | */registry.sh) continue ;; esac
    source "$f"
  done
  local m a
  for m in "${REG_MODULES[@]}"; do
    for a in ${REG_ACTIONS[$m]}; do
      declare -F "$(registry::function "$m" "$a")" >/dev/null || {
        echo "Sin implementar: $m $a"
        return 1
      }
    done
  done
}
