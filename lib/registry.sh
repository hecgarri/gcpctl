#!/usr/bin/env bash
# lib/registry.sh — Registro declarativo de módulos y acciones.
#
# Cada módulo de lib/ declara sus acciones aquí. El dispatcher (bin/gcpctl),
# la ayuda, el autocompletado y el menú interactivo (ui/menu.sh) se generan a
# partir de estos metadatos, de modo que añadir una acción no requiere tocar
# la interfaz.
# shellcheck disable=SC2034,SC2153  # Variables compartidas con core.sh y la UI.

[[ -n "${_GCPCTL_REGISTRY_LOADED:-}" ]] && return 0
_GCPCTL_REGISTRY_LOADED=1

REG_MODULES=()                 # Orden de registro de los módulos.
declare -gA REG_MODULE_DESC=() # módulo -> descripción
declare -gA REG_MODULE_APIS=() # módulo -> APIs requeridas (espacio)
declare -gA REG_MODULE_DEPS=() # módulo -> binarios extra requeridos (espacio)
declare -gA REG_ACTIONS=()     # módulo -> acciones (espacio, en orden)
declare -gA REG_MODE=()        # módulo:acción -> read | write | interactive
declare -gA REG_DESC=()        # módulo:acción -> descripción
declare -gA REG_USAGE=()       # módulo:acción -> sinopsis de argumentos
declare -gA REG_ARGS=()        # módulo:acción -> tipos de argumento para la TUI
declare -gA REG_ALIAS=()       # alias -> módulo
declare -gA REG_DEFAULT=()     # módulo -> acción por defecto (opcional)

# Registra un módulo.
# Uso: registry::module <nombre> <descripción> [apis] [deps]
registry::module() {
  REG_MODULES+=("$1")
  REG_MODULE_DESC[$1]="$2"
  REG_MODULE_APIS[$1]="${3:-}"
  REG_MODULE_DEPS[$1]="${4:-}"
  REG_ACTIONS[$1]=""
}

# Fija la acción que se ejecuta cuando se invoca el módulo sin acción.
registry::default() { REG_DEFAULT[$1]="$2"; }

# Registra un alias de módulo (p. ej. 'bq' -> 'bigquery').
registry::alias() { REG_ALIAS[$1]="$2"; }

# Registra una acción. La función que la implementa es <módulo>::<acción>
# (los '-' de la acción se convierten en '_').
# Uso: registry::action <módulo> <acción> <read|write|interactive> <desc> [uso] [args_tui]
#   args_tui: tipos separados por espacio que la TUI sabe pedir (ver ui/menu.sh),
#             p. ej. "dataset" o "datascan datascan_job". '?' al final = opcional.
registry::action() {
  local module="$1" action="$2" mode="$3"
  case "$mode" in read | write | interactive) ;; *)
    printf 'registry: modo inválido "%s" en %s %s\n' "$mode" "$module" "$action" >&2
    return 1
    ;;
  esac
  REG_ACTIONS[$module]+="${REG_ACTIONS[$module]:+ }${action}"
  REG_MODE["$module:$action"]="$mode"
  REG_DESC["$module:$action"]="$4"
  REG_USAGE["$module:$action"]="${5:-}"
  REG_ARGS["$module:$action"]="${6:-}"
}

# Resuelve un nombre (o alias) de módulo. Imprime el nombre canónico o falla.
registry::resolve_module() {
  local name="${1:-}"
  [[ -n "${REG_ALIAS[$name]:-}" ]] && name="${REG_ALIAS[$name]}"
  [[ -n "$name" && -n "${REG_MODULE_DESC[$name]+set}" ]] || return 1
  printf '%s' "$name"
}

# Devuelve 0 si la acción existe en el módulo.
registry::has_action() {
  local key="${1}:${2}"
  [[ -n "${REG_MODE[$key]+set}" ]]
}

# Imprime el nombre de la función que implementa una acción.
registry::function() { printf '%s::%s' "$1" "${2//-/_}"; }

# Lista las acciones de un módulo, una por línea.
registry::actions() {
  local a
  for a in ${REG_ACTIONS[$1]:-}; do printf '%s\n' "$a"; done
}

# Etiqueta legible del modo de una acción.
registry::mode_label() {
  local key="${1}:${2}"
  case "${REG_MODE[$key]}" in
    write) printf 'escritura' ;;
    interactive) printf 'interactiva' ;;
    *) printf 'lectura' ;;
  esac
}

# Ejecuta una acción registrada: es el punto único usado por CLI y TUI.
# Las acciones de escritura piden confirmación antes de ejecutarse.
# Uso: registry::run <módulo> <acción> [args...]
registry::run() {
  local module="$1" action="$2" fn key="${1}:${2}"
  shift 2
  registry::has_action "$module" "$action" || {
    core::error "Acción desconocida: '${module} ${action}'."
    return "$EX_USAGE"
  }
  fn="$(registry::function "$module" "$action")"
  declare -F "$fn" >/dev/null || {
    core::error "La acción '${module} ${action}' no está implementada (${fn})."
    return "$EX_ERROR"
  }
  if [[ "${REG_MODE[$key]}" == write ]]; then
    # La confirmación la realiza la propia acción mediante core::confirm_write
    # una vez validados los argumentos y resuelto el proyecto.
    _REG_WRITE_PENDING=1
  else
    _REG_WRITE_PENDING=0
  fi
  "$fn" "$@"
}

# Confirma una operación de escritura (llamada por las acciones 'write' tras
# validar argumentos). Muestra proyecto y operación.
# Uso: registry::confirm_write "descripción"
registry::confirm_write() {
  local desc="$1"
  if [[ "${_REG_WRITE_PENDING:-1}" == 1 ]]; then
    core::confirm "Operación de ESCRITURA: ${desc}${CORE_PROJECT:+ (proyecto: ${CORE_PROJECT})}"
    _REG_WRITE_PENDING=0
  fi
}

# --- Ayuda generada ------------------------------------------------------------

# Imprime la ayuda de un módulo.
registry::module_help() {
  local module="$1" a key
  printf 'Uso: gcpctl %s <acción> [opciones]\n\n%s\n\nAcciones:\n' "$module" "${REG_MODULE_DESC[$module]}"
  for a in ${REG_ACTIONS[$module]}; do
    key="$module:$a"
    printf '  %-14s %-11s %s\n' "$a" "[$(registry::mode_label "$module" "$a")]" "${REG_DESC[$key]}"
    [[ -n "${REG_USAGE[$key]}" ]] && printf '  %-14s %-11s uso: gcpctl %s %s %s\n' "" "" "$module" "$a" "${REG_USAGE[$key]}"
  done
  if [[ -n "${REG_MODULE_APIS[$module]}" ]]; then
    printf '\nAPIs requeridas: %s\n' "${REG_MODULE_APIS[$module]}"
  fi
  local al aliases=""
  for al in "${!REG_ALIAS[@]}"; do
    [[ "${REG_ALIAS[$al]}" == "$module" ]] && aliases+="${aliases:+, }$al"
  done
  [[ -n "$aliases" ]] && printf 'Alias: %s\n' "$aliases"
  return 0
}

# Imprime la ayuda de una acción concreta.
registry::action_help() {
  local module="$1" action="$2" key="$1:$2"
  printf 'Uso: gcpctl %s %s %s\n\n%s  [%s]\n' "$module" "$action" "${REG_USAGE[$key]}" \
    "${REG_DESC[$key]}" "$(registry::mode_label "$module" "$action")"
}

# Imprime la lista de módulos (para la ayuda general).
registry::modules_summary() {
  local m
  for m in "${REG_MODULES[@]}"; do
    printf '  %-12s %s\n' "$m" "${REG_MODULE_DESC[$m]}"
  done
}
