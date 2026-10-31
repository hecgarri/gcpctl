#!/usr/bin/env bash
# ui/menu.sh — Menú interactivo (TUI).
#
# Construye la navegación a partir del registro de módulos (lib/registry.sh) y
# pide los argumentos de cada acción mediante "selectores" de recursos.
# No contiene lógica de GCP: cada operación (incluidos los listados que
# alimentan los selectores) se ejecuta invocando al propio dispatcher
# (bin/gcpctl) como proceso hijo, con el contexto de la sesión en variables de
# entorno. Así CLI y TUI comparten exactamente el mismo código y un error en
# una operación nunca cierra el menú.

# shellcheck disable=SC2016,SC2153  # Expresiones jq literales; variables de core.sh.

[[ -n "${_GCPCTL_MENU_LOADED:-}" ]] && return 0
_GCPCTL_MENU_LOADED=1

MENU_ACCOUNT=""   # Cuenta activa mostrada en la cabecera.
MENU_PROJECT=""   # Proyecto mostrado en la cabecera (cacheado).
MENU_REPLY=""     # Valor devuelto por los selectores (evita subshells).
MENU_LAST_SCAN="" # Último DataScan elegido (para elegir sus jobs).

# Módulos que necesitan una ubicación y las propiedades de gcloud a consultar.
declare -gA MENU_LOCATION_PROPS=(
  [composer]="composer/location compute/region"
  [dataplex]="compute/region"
)

# --- Ejecución -----------------------------------------------------------------

# Ejecuta gcpctl como proceso hijo con el contexto de la sesión.
# Uso: menu::_exec <módulo> <acción> [args...]
menu::_exec() {
  GCPCTL_PROJECT="$GCPCTL_PROJECT" GCPCTL_FORMAT="$GCPCTL_FORMAT" \
    GCPCTL_REGION="$GCPCTL_REGION" GCPCTL_ZONE="$GCPCTL_ZONE" \
    GCPCTL_LOCATION="$GCPCTL_LOCATION" GCPCTL_DEBUG="$GCPCTL_DEBUG" \
    GCPCTL_NO_COLOR="$GCPCTL_NO_COLOR" GCPCTL_PROD_PATTERN="$GCPCTL_PROD_PATTERN" \
    GCPCTL_YES=0 GCPCTL_DRY_RUN="$GCPCTL_DRY_RUN" \
    "${GCPCTL_HOME}/bin/gcpctl" "$@"
}

# Ejecuta una acción en modo JSON y deja la salida en MENU_REPLY.
# Uso: menu::_json <módulo> <acción> [args...]
menu::_json() {
  MENU_REPLY="$(GCPCTL_FORMAT=json GCPCTL_QUIET=1 GCPCTL_DRY_RUN=0 menu::_exec "$@")" || {
    core::error "No se pudo obtener la lista de recursos."
    return 1
  }
  [[ -n "$MENU_REPLY" ]] || MENU_REPLY='[]'
}

# Convierte el JSON de MENU_REPLY en elementos "valor<TAB>etiqueta" con una
# expresión jq y muestra el selector. Deja la elección en MENU_REPLY.
# Uso: menu::_pick_json <prompt> <expresión_jq>
menu::_pick_json() {
  local prompt="$1" expr="$2" items=() line choice
  while IFS= read -r line; do
    [[ -n "$line" ]] && items+=("$line")
  done < <(jq -r "$expr" <<<"$MENU_REPLY" 2>/dev/null || true)
  if ((${#items[@]} == 0)); then
    core::warn "No se encontraron recursos."
    picker::pause
    return 1
  fi
  choice="$(picker::choose "$prompt" "$(menu::header)" "${items[@]}")" || return 1
  MENU_REPLY="$choice"
}

# --- Contexto ------------------------------------------------------------------

# Refresca proyecto y cuenta mostrados en la cabecera.
menu::refresh_context() {
  MENU_PROJECT="${GCPCTL_PROJECT:-${CLOUDSDK_CORE_PROJECT:-$(core::gcloud_prop project)}}"
  MENU_ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n1 || true)"
}

# Cabecera con el contexto activo.
menu::header() {
  local prod=""
  core::is_prod "$MENU_PROJECT" && prod=" ⚠ PRODUCCIÓN"
  printf 'gcpctl %s │ Proyecto: %s%s │ Cuenta: %s │ Salida: %s%s' \
    "${GCPCTL_VERSION:-}" "${MENU_PROJECT:-(ninguno)}" "$prod" "${MENU_ACCOUNT:-(sin autenticar)}" \
    "$GCPCTL_FORMAT" "${GCPCTL_LOCATION:+ │ Ubicación: $GCPCTL_LOCATION}"
}

# Asegura una ubicación para módulos regionales; la pide si no está configurada.
menu::ensure_location() {
  local module="$1" props="${MENU_LOCATION_PROPS[$1]:-}" p value
  [[ -n "$props" && -z "${GCPCTL_LOCATION}${GCPCTL_REGION}" ]] || return 0
  for p in $props; do
    value="$(core::gcloud_prop "$p")"
    [[ -n "$value" ]] && return 0
  done
  value="$(picker::input "Ubicación/región para ${module} (p. ej. europe-west1)")" || return 1
  if [[ ! "$value" =~ ^[a-z0-9-]+$ ]]; then
    core::error "Ubicación no válida: '${value}'."
    return 1
  fi
  GCPCTL_LOCATION="$value"
}

# --- Selectores de recursos (uno por tipo declarado en REG_ARGS) ---------------
# Cada selector deja el valor elegido en MENU_REPLY y puede fijar contexto
# (zona/región/ubicación) para la acción en curso.

menu::ask_project() {
  menu::_json projects list || return 1
  menu::_pick_json "Proyecto" '.[] | "\(.projectId)\t\(.projectId)  —  \(.name // "")"'
}

menu::ask_configuration() {
  menu::_json config list || return 1
  menu::_pick_json "Configuración" '.[] | "\(.name)\t\(.name)\(if .is_active then "  (activa)" else "" end)  —  \(.properties.core.project // "")"'
}

menu::ask_dataset() {
  menu::_json bigquery datasets || return 1
  menu::_pick_json "Dataset" '.[] | "\(.datasetReference.datasetId)\t\(.datasetReference.datasetId)  [\(.location // "")]"'
}

menu::ask_table() {
  menu::ask_dataset || return 1
  local dataset="$MENU_REPLY"
  menu::_json bigquery tables "$dataset" || return 1
  menu::_pick_json "Tabla de ${dataset}" \
    '.[] | "\(.tableReference.datasetId).\(.tableReference.tableId)\t\(.tableReference.tableId)  (\(.type // ""))"'
}

menu::ask_composer_env() {
  menu::ensure_location composer || return 1
  menu::_json composer list || return 1
  menu::_pick_json "Entorno" \
    '.[] | "\(.name)\t\(.name | split("/") | last)  [\(.state // "")]  \(.config.softwareConfig.imageVersion // "")"' || return 1
  # Nombre completo: projects/P/locations/L/environments/E
  GCPCTL_LOCATION="$(cut -d/ -f4 <<<"$MENU_REPLY")"
  MENU_REPLY="${MENU_REPLY##*/}"
}

menu::ask_datascan() {
  menu::ensure_location dataplex || return 1
  menu::_json dataplex scans || return 1
  menu::_pick_json "DataScan" \
    '.[] | "\(.name | split("/") | last)\t\(.name | split("/") | last)  [\(.type // "")]  \((.data.resource // .data.entity // "") | split("/") | last)"' || return 1
  MENU_LAST_SCAN="$MENU_REPLY"
}

menu::ask_datascan_job() {
  if [[ -z "$MENU_LAST_SCAN" ]]; then
    core::error "Elige primero un DataScan."
    return 1
  fi
  menu::_json dataplex jobs "$MENU_LAST_SCAN" || return 1
  menu::_pick_json "Ejecución" '.[] | "\(.name | split("/") | last)\t\(.startTime // "")  \(.state // "")  \(.name | split("/") | last)"'
}

menu::ask_entry_group() {
  menu::ensure_location dataplex || return 1
  menu::_json dataplex entry-groups || return 1
  menu::_pick_json "Grupo de entradas" '.[] | "\(.name | split("/") | last)\t\(.name | split("/") | last)  \(.displayName // "")"'
}

menu::ask_instance() {
  menu::_json compute list || return 1
  menu::_pick_json "Instancia" \
    '.[] | "\(.name)|\(.zone | split("/") | last)\t\(.name)  [\(.status)]  \(.zone | split("/") | last)"' || return 1
  GCPCTL_ZONE="${MENU_REPLY#*|}"
  MENU_REPLY="${MENU_REPLY%%|*}"
}

menu::ask_run_service() {
  menu::_json cloudrun list || return 1
  menu::_pick_json "Servicio" \
    '.[] | (.metadata.labels["cloud.googleapis.com/location"] // "") as $r | "\(.metadata.name)|\($r)\t\(.metadata.name)  [\($r)]  \(.status.url // "")"' || return 1
  local region="${MENU_REPLY#*|}"
  [[ -n "$region" ]] && GCPCTL_REGION="$region"
  MENU_REPLY="${MENU_REPLY%%|*}"
}

menu::ask_service_account() {
  menu::_json iam sa || return 1
  menu::_pick_json "Cuenta de servicio" '.[] | "\(.email)\t\(.email)  \(.displayName // "")"'
}

menu::ask_logging_service() {
  local items=() k
  for k in $(printf '%s\n' "${!LOGGING_SERVICE_FILTERS[@]}" | sort); do items+=("$k"); done
  MENU_REPLY="$(picker::choose "Servicio" "$(menu::header)" "${items[@]}")"
}

# Pide un texto libre. Uso: menu::ask_text "Etiqueta"
menu::ask_text() {
  MENU_REPLY="$(picker::input "$1")"
}

# Divide una especificación REG_ARGS en tipos (los 'text:Etiqueta' pueden
# contener espacios y terminan donde empieza el siguiente ' text:').
# Uso: menu::_split_kinds <spec> ; resultado en MENU_KINDS
menu::_split_kinds() {
  local spec="$1" label
  MENU_KINDS=()
  while [[ -n "$spec" ]]; do
    if [[ "$spec" == text:* ]]; then
      label="${spec#text:}"
      if [[ "$label" == *" text:"* ]]; then
        MENU_KINDS+=("text:${label%% text:*}")
        spec="text:${label#* text:}"
      else
        MENU_KINDS+=("text:${label}")
        spec=""
      fi
    else
      MENU_KINDS+=("${spec%% *}")
      if [[ "$spec" == *" "* ]]; then spec="${spec#* }"; else spec=""; fi
    fi
  done
}

# --- Navegación ----------------------------------------------------------------

# Recoge los argumentos de una acción y la ejecuta.
menu::run_action() {
  local module="$1" action="$2" kind optional args=() rc=0
  # Copias locales: los selectores cambian el contexto sólo para esta acción.
  local GCPCTL_ZONE="$GCPCTL_ZONE" GCPCTL_REGION="$GCPCTL_REGION" GCPCTL_LOCATION="$GCPCTL_LOCATION"

  menu::ensure_location "$module" || return 0
  local key="${module}:${action}"
  menu::_split_kinds "${REG_ARGS[$key]:-}"
  for kind in "${MENU_KINDS[@]}"; do
    optional=0
    if [[ "$kind" == *\? ]]; then
      optional=1
      kind="${kind%\?}"
    fi
    if ((optional)) && ! picker::confirm "¿Indicar ${kind//_/ }? (opcional)"; then
      continue
    fi
    if [[ "$kind" == text:* ]]; then
      menu::ask_text "${kind#text:}" || return 0
    else
      "menu::ask_${kind}" || return 0
    fi
    args+=("$MENU_REPLY")
  done

  printf '\n%s▶ gcpctl %s %s %s%s\n\n' "$C_BOLD" "$module" "$action" "$(core::quote_cmd "${args[@]}")" "$C_RESET" >&2
  menu::_exec "$module" "$action" "${args[@]}" || rc=$?
  if ((rc == EX_CANCELLED)); then
    core::warn "Operación cancelada."
  elif ((rc != 0)); then
    core::error "La operación terminó con errores (código ${rc})."
  fi
  [[ "${REG_MODE[$key]}" == write ]] && menu::refresh_context
  picker::pause
}

# Menú de un módulo: lista sus acciones (marcando escritura e interactivas).
menu::module() {
  local module="$1" items=() a choice tag key
  while true; do
    items=()
    for a in ${REG_ACTIONS[$module]}; do
      tag=""
      key="${module}:${a}"
      case "${REG_MODE[$key]}" in
        write) tag="  ✎ escritura" ;;
        interactive) tag="  ⇄ interactiva" ;;
      esac
      items+=("${a}"$'\t'"$(printf '%-14s %s%s' "$a" "${REG_DESC[$key]}" "$tag")")
    done
    choice="$(picker::choose "$module" "$(menu::header)" "${items[@]}")" || return 0
    menu::run_action "$module" "$choice"
  done
}

# Cambia el proyecto de la sesión y, opcionalmente, lo persiste en gcloud.
menu::change_project() {
  menu::ask_project || return 0
  GCPCTL_PROJECT="$MENU_REPLY"
  MENU_PROJECT="$MENU_REPLY"
  core::ok "Proyecto de la sesión: ${GCPCTL_PROJECT}"
  if picker::confirm "¿Guardarlo también en la configuración activa de gcloud?"; then
    menu::_exec projects use "$GCPCTL_PROJECT" || true
    picker::pause
  fi
}

# Cambia el formato de salida.
menu::change_format() {
  local choice
  choice="$(picker::choose "Formato" "$(menu::header)" table json yaml csv)" || return 0
  GCPCTL_FORMAT="$choice"
}

# Bucle principal del menú interactivo.
menu::main() {
  core::is_interactive || core::die "El modo interactivo requiere una terminal." "$EX_USAGE"
  menu::refresh_context
  [[ -n "$MENU_ACCOUNT" ]] || core::warn "No hay cuenta autenticada: ejecuta 'gcloud auth login'."
  [[ "$(picker::backend)" == fzf ]] ||
    core::info "fzf no está instalado: se usa el menú básico (instala fzf para búsqueda incremental)."

  local items m choice
  while true; do
    items=()
    for m in "${REG_MODULES[@]}"; do
      items+=("${m}"$'\t'"$(printf '%-10s %s' "$m" "${REG_MODULE_DESC[$m]}")")
    done
    items+=(
      "@project"$'\t'"⚙ Cambiar proyecto de la sesión"
      "@format"$'\t'"⚙ Formato de salida (${GCPCTL_FORMAT})"
      "@quit"$'\t'"✕ Salir"
    )
    choice="$(picker::choose "gcpctl" "$(menu::header)" "${items[@]}")" || return 0
    case "$choice" in
      @quit) return 0 ;;
      @project) menu::change_project ;;
      @format) menu::change_format ;;
      *) menu::module "$choice" ;;
    esac
  done
}
