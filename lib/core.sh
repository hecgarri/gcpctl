#!/usr/bin/env bash
# lib/core.sh — Núcleo de gcpctl: logging, errores, dependencias, contexto
# (proyecto/formato/ubicación), ejecución segura de gcloud/bq y confirmaciones.
#
# Este archivo sólo define funciones y variables; no ejecuta nada al cargarse.
# shellcheck disable=SC2034  # Variables usadas por otros módulos.

[[ -n "${_GCPCTL_CORE_LOADED:-}" ]] && return 0
_GCPCTL_CORE_LOADED=1

# --- Códigos de salida ---------------------------------------------------------
readonly EX_OK=0
readonly EX_ERROR=1
readonly EX_USAGE=2
readonly EX_DEPENDENCY=3
readonly EX_API=4
readonly EX_CANCELLED=130

# --- Contexto global (rellenado por el dispatcher o por variables de entorno) --
GCPCTL_PROJECT="${GCPCTL_PROJECT:-}"
GCPCTL_FORMAT="${GCPCTL_FORMAT:-table}"
GCPCTL_REGION="${GCPCTL_REGION:-}"
GCPCTL_ZONE="${GCPCTL_ZONE:-}"
GCPCTL_LOCATION="${GCPCTL_LOCATION:-}"
GCPCTL_YES="${GCPCTL_YES:-0}"
GCPCTL_DRY_RUN="${GCPCTL_DRY_RUN:-0}"
GCPCTL_QUIET="${GCPCTL_QUIET:-0}"
GCPCTL_DEBUG="${GCPCTL_DEBUG:-0}"
GCPCTL_NO_COLOR="${GCPCTL_NO_COLOR:-0}"
# Expresión regular (ERE) que identifica proyectos de producción.
GCPCTL_PROD_PATTERN="${GCPCTL_PROD_PATTERN:-(^|[-_])(prod|prd|production)([-_]|$)}"

# Proyecto resuelto para la invocación actual (lo fija core::ensure_project).
CORE_PROJECT=""
# Último mensaje de error traducido (útil para la TUI).
CORE_LAST_ERROR=""

# --- Colores y logging ---------------------------------------------------------

# Inicializa los códigos de color si stderr es una terminal y no se desactivaron.
core::init_colors() {
  if [[ -t 2 && "${GCPCTL_NO_COLOR}" != 1 && -z "${NO_COLOR:-}" ]]; then
    C_RED=$'\033[31m' C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m' C_BOLD=$'\033[1m' C_DIM=$'\033[2m' C_RESET=$'\033[0m'
  else
    C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_BOLD="" C_DIM="" C_RESET=""
  fi
}
core::init_colors

# Mensaje informativo a stderr (silenciado con --quiet).
core::info() {
  [[ "${GCPCTL_QUIET}" == 1 ]] && return 0
  printf '%s%s%s\n' "${C_BLUE}" "$*" "${C_RESET}" >&2
}

# Mensaje de éxito a stderr (silenciado con --quiet).
core::ok() {
  [[ "${GCPCTL_QUIET}" == 1 ]] && return 0
  printf '%s✔ %s%s\n' "${C_GREEN}" "$*" "${C_RESET}" >&2
}

# Advertencia a stderr.
core::warn() { printf '%sAviso:%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }

# Error a stderr.
core::error() { printf '%sError:%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; }

# Traza de depuración (sólo con --debug).
core::debug() {
  [[ "${GCPCTL_DEBUG}" == 1 ]] || return 0
  printf '%s[debug] %s%s\n' "${C_DIM}" "$*" "${C_RESET}" >&2
}

# Muestra un error y termina con el código indicado (por defecto 1).
# Uso: core::die "mensaje" [código]
core::die() {
  core::error "$1"
  exit "${2:-$EX_ERROR}"
}

# Error de uso: muestra el mensaje y una pista, sale con código 2.
core::usage_error() {
  core::error "$1"
  [[ -n "${2:-}" ]] && printf '  %s\n' "$2" >&2
  exit "$EX_USAGE"
}

# --- Utilidades ----------------------------------------------------------------

# Devuelve 0 si el comando existe en el PATH.
core::has_cmd() { command -v "$1" >/dev/null 2>&1; }

# Falla con un mensaje claro si falta un comando requerido.
# Uso: core::require_cmd <cmd> [pista de instalación]
core::require_cmd() {
  core::has_cmd "$1" && return 0
  core::error "No se encontró la dependencia requerida '$1'."
  [[ -n "${2:-}" ]] && printf '  %s\n' "$2" >&2
  exit "$EX_DEPENDENCY"
}

# Comprueba la versión mínima de Bash (4.4: arrays vacíos seguros con set -u).
core::check_bash() {
  if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
    printf 'Error: gcpctl requiere Bash >= 4.4 (actual: %s)\n' "${BASH_VERSION}" >&2
    exit "$EX_DEPENDENCY"
  fi
}

# Valida las dependencias obligatorias. Uso: core::check_deps [bq]
core::check_deps() {
  core::require_cmd gcloud "Instala Google Cloud CLI: https://cloud.google.com/sdk/docs/install"
  core::require_cmd jq "Instala jq (p. ej. 'sudo apt install jq')."
  local extra
  for extra in "$@"; do
    case "$extra" in
      bq) core::require_cmd bq "bq forma parte de Google Cloud CLI: 'gcloud components install bq'." ;;
      *) core::require_cmd "$extra" ;;
    esac
  done
}

# Devuelve 0 si la sesión es interactiva (stdin es TTY o se fuerza en pruebas).
core::is_interactive() {
  [[ -t 0 || "${GCPCTL_FORCE_INTERACTIVE:-0}" == 1 ]]
}

# Valida un identificador de recurso (sin espacios, sin '-' inicial, longitud razonable).
# Uso: core::validate_id <tipo> <valor>
core::validate_id() {
  local kind="$1" value="${2:-}"
  if [[ -z "$value" ]]; then
    core::usage_error "Falta el argumento obligatorio: ${kind}."
  fi
  if [[ "$value" == -* || ! "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._:@/-]{0,1023}$ ]]; then
    core::usage_error "Valor no válido para ${kind}: '${value}'."
  fi
}

# Falla si una opción que requiere valor no lo recibió.
# Uso: core::need_value <opción> "${2:-}"
core::need_value() {
  [[ -n "${2:-}" && "${2:-}" != --* ]] || core::usage_error "La opción $1 requiere un valor."
}

# Valida un entero positivo. Uso: core::validate_int <nombre> <valor>
core::validate_int() {
  [[ "${2:-}" =~ ^[1-9][0-9]{0,6}$ ]] || core::usage_error "'$1' debe ser un entero positivo (recibido: '${2:-}')."
}

# Escapa un valor para incluirlo entre comillas dobles en un filtro de gcloud/Logging.
core::filter_quote() {
  local v="${1//\\/\\\\}"
  printf '"%s"' "${v//\"/\\\"}"
}

# Imprime un TSV (stdin) alineado en columnas si 'column' está disponible.
core::columns() {
  if core::has_cmd column; then
    column -t -s $'\t'
  else
    cat
  fi
}

# --- Contexto: proyecto, ubicaciones, formato ----------------------------------

# Lee una propiedad de la configuración activa de gcloud (vacío si no existe).
core::gcloud_prop() {
  local value
  value="$(gcloud config get-value "$1" 2>/dev/null || true)"
  [[ "$value" == "(unset)" ]] && value=""
  printf '%s' "$value"
}

# Resuelve el proyecto: --project > CLOUDSDK_CORE_PROJECT > configuración activa.
# Fija CORE_PROJECT y falla si no hay ninguno. No modifica la configuración global.
core::ensure_project() {
  [[ -n "$CORE_PROJECT" ]] && return 0
  CORE_PROJECT="${GCPCTL_PROJECT:-${CLOUDSDK_CORE_PROJECT:-}}"
  [[ -z "$CORE_PROJECT" ]] && CORE_PROJECT="$(core::gcloud_prop project)"
  if [[ -z "$CORE_PROJECT" ]]; then
    core::usage_error "No hay un proyecto activo." \
      "Usa '--project <ID>' o fija uno con 'gcpctl projects use <ID>'."
  fi
  core::validate_id "proyecto" "$CORE_PROJECT"
  core::debug "proyecto: $CORE_PROJECT"
}

# Imprime la ubicación a usar: --location > --region > GCPCTL_LOCATION >
# propiedades de gcloud indicadas (en orden). Falla si no hay ninguna.
# Uso: loc="$(core::resolve_location <servicio> [prop...])"
core::resolve_location() {
  local service="$1" prop value="${GCPCTL_LOCATION:-${GCPCTL_REGION:-}}"
  shift
  if [[ -z "$value" ]]; then
    for prop in "$@"; do
      value="$(core::gcloud_prop "$prop")"
      [[ -n "$value" ]] && break
    done
  fi
  if [[ -z "$value" ]]; then
    core::error "${service} requiere una ubicación (región)."
    printf '  Usa --location <región> o configura una: gcloud config set %s <región>\n' "${1:-compute/region}" >&2
    exit "$EX_USAGE"
  fi
  core::validate_id "ubicación" "$value"
  printf '%s' "$value"
}

# Valida el formato de salida solicitado.
core::validate_format() {
  case "$GCPCTL_FORMAT" in
    table | json | yaml | csv) ;;
    *) core::usage_error "Formato no soportado: '${GCPCTL_FORMAT}'." "Valores válidos: table, json, yaml, csv." ;;
  esac
}

# Devuelve 0 si la salida solicitada es legible por humanos (table).
core::is_table() { [[ "$GCPCTL_FORMAT" == table ]]; }

# Devuelve 0 si se debe generar un resumen propio (tabla y sin --dry-run).
core::wants_summary() { core::is_table && [[ "$GCPCTL_DRY_RUN" != 1 ]]; }

# Imprime el flag --format de gcloud según el formato global.
# Uso: core::gcloud_format "table(name,status)"   (proyección para modo tabla/csv)
core::gcloud_format() {
  local projection="${1:-}"
  case "$GCPCTL_FORMAT" in
    json) printf -- '--format=json' ;;
    yaml) printf -- '--format=yaml' ;;
    csv)
      if [[ "$projection" == table\(* ]]; then
        printf -- '--format=csv%s' "${projection#table}"
      else
        printf -- '--format=csv'
      fi
      ;;
    *)
      if [[ -n "$projection" ]]; then
        printf -- '--format=%s' "$projection"
      else
        printf -- '--format=table'
      fi
      ;;
  esac
}

# Imprime el valor de --format para bq según el formato global.
core::bq_format() {
  case "$GCPCTL_FORMAT" in
    json) printf 'prettyjson' ;;
    csv) printf 'csv' ;;
    yaml)
      core::warn "bq no soporta YAML; se usará JSON."
      printf 'prettyjson'
      ;;
    *) printf 'pretty' ;;
  esac
}

# Devuelve 0 si el proyecto (por defecto el actual) parece de producción.
core::is_prod() {
  local project="${1:-${CORE_PROJECT:-${GCPCTL_PROJECT:-}}}"
  [[ -n "$project" ]] || return 1
  [[ "$project" =~ $GCPCTL_PROD_PATTERN ]]
}

# --- Confirmaciones ------------------------------------------------------------

# Devuelve 0 si hay una terminal de control utilizable (/dev/tty se puede abrir).
# GCPCTL_NO_TTY=1 lo desactiva (pruebas, CI).
core::has_tty() {
  [[ "${GCPCTL_NO_TTY:-0}" != 1 ]] || return 1
  { : </dev/tty; } 2>/dev/null
}

# Lee una línea del usuario desde la terminal (o stdin en pruebas).
core::_read_answer() {
  local answer=""
  if [[ "${GCPCTL_FORCE_INTERACTIVE:-0}" != 1 && ! -t 0 ]] && core::has_tty; then
    IFS= read -r answer </dev/tty || true
  else
    IFS= read -r answer || true
  fi
  printf '%s' "$answer"
}

# Pide confirmación antes de una operación de escritura.
# - En dry-run no pregunta (no se ejecuta nada).
# - En proyectos de producción exige escribir el ID del proyecto, salvo
#   GCPCTL_FORCE_PROD=1 (automatización explícita).
# - En el resto, --yes omite la pregunta.
# Uso: core::confirm "descripción de la operación"
core::confirm() {
  local message="$1" project="${CORE_PROJECT:-${GCPCTL_PROJECT:-}}" answer
  [[ "$GCPCTL_DRY_RUN" == 1 ]] && return 0

  if core::is_prod "$project"; then
    [[ "${GCPCTL_FORCE_PROD:-0}" == 1 ]] && return 0
    if ! core::is_interactive && ! core::has_tty; then
      core::die "Operación de escritura en PRODUCCIÓN ('${project}') sin terminal: cancelada. Usa GCPCTL_FORCE_PROD=1 si es intencionado." "$EX_CANCELLED"
    fi
    printf '%s⚠  PRODUCCIÓN%s — %s\n' "${C_RED}${C_BOLD}" "${C_RESET}" "$message" >&2
    printf 'Escribe el ID del proyecto (%s) para confirmar: ' "$project" >&2
    answer="$(core::_read_answer)"
    [[ "$answer" == "$project" ]] && return 0
    core::die "Confirmación incorrecta: operación cancelada." "$EX_CANCELLED"
  fi

  [[ "$GCPCTL_YES" == 1 ]] && return 0
  if ! core::is_interactive && ! core::has_tty; then
    core::die "Se requiere confirmación y no hay terminal. Usa --yes para continuar." "$EX_CANCELLED"
  fi
  printf '%s%s%s\n¿Continuar? [s/N]: ' "${C_YELLOW}" "$message" "${C_RESET}" >&2
  answer="$(core::_read_answer)"
  case "${answer,,}" in
    s | si | sí | y | yes) return 0 ;;
    *) core::die "Operación cancelada." "$EX_CANCELLED" ;;
  esac
}

# --- Ejecución de gcloud / bq --------------------------------------------------

# Crea (una vez por proceso) un directorio temporal en _CORE_TMPDIR que se
# elimina al salir. Debe llamarse sin subshell para que la variable persista.
core::ensure_tmpdir() {
  if [[ -z "${_CORE_TMPDIR:-}" || ! -d "${_CORE_TMPDIR}" || "${_CORE_TMPDIR_PID:-}" != "${BASHPID}" ]]; then
    _CORE_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/gcpctl.XXXXXX")"
    _CORE_TMPDIR_PID="${BASHPID}"
    # shellcheck disable=SC2064  # Se expande ahora a propósito.
    trap "rm -rf '${_CORE_TMPDIR}'" EXIT
  fi
}

# Imprime un comando citado de forma segura (para --dry-run y --debug).
core::quote_cmd() {
  local out="" arg
  for arg in "$@"; do out+="$(printf '%q' "$arg") "; done
  printf '%s' "${out% }"
}

# Traduce la salida de error de gcloud/bq a un mensaje accionable.
# Imprime la explicación en stderr y devuelve el código de salida a usar.
# Uso: core::explain_error <archivo_stderr> <código_original>
core::explain_error() {
  local file="$1" rc="$2" text api hint="" code="$EX_ERROR"
  text="$(cat "$file" 2>/dev/null || true)"
  CORE_LAST_ERROR="$text"

  local lc="${text,,}" sp='[[:space:]]'
  if [[ "$lc" =~ (service_disabled|has${sp}not${sp}been${sp}used|api${sp}has${sp}not${sp}been|is${sp}disabled) ]]; then
    api="$(grep -oE '[a-z0-9-]+\.googleapis\.com' "$file" | head -n1 || true)"
    hint="La API ${api:-requerida} no está habilitada en el proyecto. Habilítala con:
    gcloud services enable ${api:-<api>.googleapis.com} --project ${CORE_PROJECT:-<proyecto>}"
    code="$EX_API"
  elif [[ "$lc" =~ (reauthentication|invalid_grant|no${sp}active${sp}account|do${sp}not${sp}currently${sp}have${sp}an${sp}active${sp}account|gcloud${sp}auth${sp}login) ]]; then
    hint="Credenciales ausentes o caducadas. Ejecuta: gcloud auth login"
    code="$EX_API"
  elif [[ "$lc" =~ (permission_denied|does${sp}not${sp}have${sp}permission|permission${sp}denied|access${sp}denied|forbidden) ]]; then
    hint="Permisos IAM insuficientes en '${CORE_PROJECT:-el proyecto}'. Revisa tus roles con 'gcpctl iam policy' o solicita el rol adecuado."
    code="$EX_API"
  elif [[ "$lc" =~ (not_found|not${sp}found) ]]; then
    hint="El recurso no existe o no es visible con la cuenta/proyecto/ubicación actuales."
  elif [[ "$lc" =~ (invalid${sp}choice|unrecognized${sp}arguments|is${sp}not${sp}a${sp}valid${sp}command) ]]; then
    hint="Tu versión de Google Cloud CLI no soporta este comando. Actualiza con 'gcloud components update'."
    code="$EX_DEPENDENCY"
  elif [[ "$lc" =~ (component.*not${sp}installed|requires${sp}the${sp}.*component) ]]; then
    hint="Falta un componente de Google Cloud CLI. Revisa 'gcloud components list'."
    code="$EX_DEPENDENCY"
  fi

  if [[ -n "$text" ]]; then
    local max=4 total
    total="$(grep -c '' <<<"$text")"
    if [[ "$GCPCTL_DEBUG" == 1 ]] || ((total <= max)); then
      printf '%s\n' "$text" | sed 's/^/  │ /' >&2
    else
      printf '%s\n' "$text" | head -n "$max" | sed 's/^/  │ /' >&2
      printf '  │ … (%d líneas más; usa --debug para verlas)\n' "$((total - max))" >&2
    fi
  fi
  core::error "El comando falló (código ${rc})."
  [[ -n "$hint" ]] && printf '  %s→ %s%s\n' "${C_BOLD}" "$hint" "${C_RESET}" >&2
  return "$code"
}

# Construye en el array <destino> el comando con los argumentos extra insertados
# antes del primer '--' (o al final), para no pasarlos a comandos anidados.
# Uso: core::_build_cmd <destino> <n_extra> <extra...> <cmd...>
core::_build_cmd() {
  local -n _out="$1"
  local n="$2" i seen=0
  shift 2
  local extras=("${@:1:n}")
  shift "$n"
  _out=()
  for i in "$@"; do
    if [[ "$i" == "--" && "$seen" == 0 ]]; then
      _out+=("${extras[@]}")
      seen=1
    fi
    _out+=("$i")
  done
  [[ "$seen" == 0 ]] && _out+=("${extras[@]}")
  return 0
}

# Ejecuta un comando capturando stderr para traducir errores. stdout fluye tal cual.
core::_run() {
  local errf rc=0
  if [[ "$GCPCTL_DRY_RUN" == 1 ]]; then
    printf '[dry-run] %s\n' "$(core::quote_cmd "$@")"
    return 0
  fi
  core::debug "exec: $(core::quote_cmd "$@")"
  core::ensure_tmpdir
  errf="$(mktemp "${_CORE_TMPDIR}/err.XXXXXX")"
  "$@" 2>"$errf" || rc=$?
  if ((rc != 0)); then
    core::explain_error "$errf" "$rc" || rc=$?
    rm -f "$errf"
    return "$rc"
  fi
  # Mensajes informativos de gcloud (p. ej. "Listed 0 items.").
  if [[ -s "$errf" && "$GCPCTL_QUIET" != 1 ]]; then
    sed "s/^/${C_DIM}/; s/\$/${C_RESET}/" "$errf" >&2
  fi
  rm -f "$errf"
  return 0
}

# Ejecuta gcloud de forma no interactiva (--quiet) con el proyecto resuelto.
# Uso: core::gcloud <args...>   (el proyecto se añade si CORE_PROJECT está fijado)
core::gcloud() {
  local extras=(--quiet) cmd=()
  [[ -n "$CORE_PROJECT" ]] && extras+=("--project=${CORE_PROJECT}")
  core::_build_cmd cmd "${#extras[@]}" "${extras[@]}" gcloud "$@"
  core::_run "${cmd[@]}"
}

# Ejecuta gcloud sin capturar stderr ni forzar --quiet (comandos interactivos: ssh).
core::gcloud_interactive() {
  local extras=() cmd=()
  [[ -n "$CORE_PROJECT" ]] && extras+=("--project=${CORE_PROJECT}")
  core::_build_cmd cmd "${#extras[@]}" "${extras[@]}" gcloud "$@"
  if [[ "$GCPCTL_DRY_RUN" == 1 ]]; then
    printf '[dry-run] %s\n' "$(core::quote_cmd "${cmd[@]}")"
    return 0
  fi
  core::debug "exec: $(core::quote_cmd "${cmd[@]}")"
  "${cmd[@]}"
}

# Ejecuta bq en modo headless con proyecto y formato globales.
# bq a veces escribe los errores en stdout, por lo que ambos se capturan.
# Uso: core::bq <subcomando> [args...]
core::bq() {
  local cmd=(bq --headless "--format=$(core::bq_format)")
  [[ -n "$CORE_PROJECT" ]] && cmd+=("--project_id=${CORE_PROJECT}")
  cmd+=("$@")
  if [[ "$GCPCTL_DRY_RUN" == 1 ]]; then
    printf '[dry-run] %s\n' "$(core::quote_cmd "${cmd[@]}")"
    return 0
  fi
  core::debug "exec: $(core::quote_cmd "${cmd[@]}")"
  local outf rc=0
  core::ensure_tmpdir
  outf="$(mktemp "${_CORE_TMPDIR}/bq.XXXXXX")"
  "${cmd[@]}" >"$outf" 2>&1 || rc=$?
  if ((rc != 0)); then
    core::explain_error "$outf" "$rc" || rc=$?
    rm -f "$outf"
    return "$rc"
  fi
  if [[ -s "$outf" ]]; then
    cat "$outf"
  elif [[ "$GCPCTL_FORMAT" == json ]]; then
    printf '[]\n'
  else
    core::info "(sin resultados)"
  fi
  rm -f "$outf"
}

# Ejecuta gcloud y devuelve JSON por stdout (independiente del formato global).
# Uso: json="$(core::gcloud_json <args...>)"
core::gcloud_json() {
  local GCPCTL_DRY_RUN=0
  core::gcloud "$@" --format=json
}
