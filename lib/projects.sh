#!/usr/bin/env bash
# lib/projects.sh — Proyectos, cuenta autenticada, regiones/zonas y
# configuraciones de gcloud (módulos 'projects' y 'config').

registry::module projects "Proyectos, cuenta activa, regiones y zonas" "cloudresourcemanager.googleapis.com"
registry::alias project projects
registry::action projects list read "Lista los proyectos accesibles" "[--filter EXPR] [--limit N]"
registry::action projects current read "Muestra el proyecto activo y su origen"
registry::action projects use write "Fija el proyecto de la configuración activa de gcloud" "<PROJECT_ID>" "project"
registry::action projects describe read "Muestra los detalles de un proyecto" "[PROJECT_ID]" "project?"
registry::action projects whoami read "Muestra la cuenta autenticada y las credenciales disponibles"
registry::action projects regions read "Región y zona configuradas (--all: regiones disponibles)" "[--all]"
registry::action projects zones read "Zonas disponibles de Compute Engine" "[--region REGION]"

registry::module config "Configuraciones de gcloud (perfiles)"
registry::alias configs config
registry::action config list read "Lista las configuraciones de gcloud"
registry::action config show read "Muestra las propiedades de la configuración activa"
registry::action config activate write "Activa una configuración" "<NOMBRE>" "configuration"
registry::action config create write "Crea una configuración (no la activa)" "<NOMBRE>" "text:Nombre de la configuración"
registry::action config set write "Fija una propiedad en la configuración activa" "<CLAVE> <VALOR>" "text:Propiedad (p. ej. compute/region) text:Valor"
registry::action config unset write "Elimina una propiedad de la configuración activa" "<CLAVE>" "text:Propiedad"

# --- projects ------------------------------------------------------------------

# Lista proyectos. Opciones: --filter EXPR, --limit N.
projects::list() {
  local args=(projects list --sort-by=projectId)
  while (($#)); do
    case "$1" in
      --filter) core::need_value "$1" "${2:-}" && args+=("--filter=$2") && shift 2 ;;
      --limit) core::validate_int --limit "${2:-}" && args+=("--limit=$2") && shift 2 ;;
      *) core::usage_error "Opción desconocida: $1" "Uso: gcpctl projects list [--filter EXPR] [--limit N]" ;;
    esac
  done
  core::gcloud "${args[@]}" "$(core::gcloud_format 'table(projectId,name,projectNumber,lifecycleState)')"
}

# Muestra el proyecto en uso y de dónde se obtiene.
projects::current() {
  local source="configuración de gcloud" project="${GCPCTL_PROJECT:-}"
  if [[ -n "$project" ]]; then
    source="opción --project / GCPCTL_PROJECT"
  elif [[ -n "${CLOUDSDK_CORE_PROJECT:-}" ]]; then
    project="$CLOUDSDK_CORE_PROJECT" source="variable CLOUDSDK_CORE_PROJECT"
  else
    project="$(core::gcloud_prop project)"
  fi
  [[ -z "$project" ]] && core::die "No hay proyecto activo. Usa 'gcpctl projects use <ID>'." "$EX_USAGE"
  local config
  config="$(gcloud config configurations list --filter=is_active=true --format='value(name)' 2>/dev/null || true)"
  if core::is_table; then
    printf 'Proyecto:       %s\nOrigen:         %s\nConfiguración:  %s\nProducción:     %s\n' \
      "$project" "$source" "${config:-?}" "$(core::is_prod "$project" && echo sí || echo no)"
  else
    jq -n --arg p "$project" --arg s "$source" --arg c "$config" \
      --argjson prod "$(core::is_prod "$project" && echo true || echo false)" \
      '{project:$p, source:$s, configuration:$c, production:$prod}'
  fi
}

# Fija el proyecto de la configuración activa (modifica la configuración global).
projects::use() {
  local project="${1:-}"
  core::validate_id "PROJECT_ID" "$project"
  CORE_PROJECT="$project"
  registry::confirm_write "gcloud config set project ${project}"
  CORE_PROJECT=""
  core::gcloud config set project "$project"
  core::ok "Proyecto activo: ${project}"
}

# Describe un proyecto (por defecto el activo).
projects::describe() {
  local project="${1:-}"
  if [[ -z "$project" ]]; then
    core::ensure_project
    project="$CORE_PROJECT"
  fi
  core::validate_id "PROJECT_ID" "$project"
  core::gcloud projects describe "$project" "$(core::gcloud_format 'yaml')"
}

# Muestra la cuenta activa, las cuentas acreditadas y si existen ADC.
projects::whoami() {
  local adc="${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}/application_default_credentials.json"
  if core::is_table; then
    core::gcloud auth list "$(core::gcloud_format 'table(account,status)')"
    printf '\nCredenciales ADC: %s\n' "$([[ -f "$adc" ]] && echo "presentes" || echo "no configuradas (gcloud auth application-default login)")"
  else
    core::gcloud auth list "$(core::gcloud_format)"
  fi
}

# Muestra región y zona configuradas; con --all lista las regiones disponibles.
projects::regions() {
  if [[ "${1:-}" == --all ]]; then
    core::ensure_project
    core::gcloud compute regions list "$(core::gcloud_format 'table(name,status,zones.len():label=ZONES)')"
    return
  fi
  [[ $# -gt 0 ]] && core::usage_error "Opción desconocida: $1" "Uso: gcpctl projects regions [--all]"
  local props=(compute/region compute/zone run/region composer/location dataproc/region) p
  if core::is_table; then
    local v
    for p in "${props[@]}"; do
      v="$(core::gcloud_prop "$p")"
      printf '%-20s %s\n' "$p" "${v:-(sin definir)}"
    done
    [[ -n "$GCPCTL_REGION$GCPCTL_ZONE$GCPCTL_LOCATION" ]] &&
      printf '\nSobrescrito en esta ejecución: region=%s zone=%s location=%s\n' "${GCPCTL_REGION:--}" "${GCPCTL_ZONE:--}" "${GCPCTL_LOCATION:--}"
  else
    local json='{}'
    for p in "${props[@]}"; do
      json="$(jq --arg k "$p" --arg v "$(core::gcloud_prop "$p")" '. + {($k): (if $v == "" then null else $v end)}' <<<"$json")"
    done
    printf '%s\n' "$json"
  fi
  return 0
}

# Lista zonas de Compute Engine (opcionalmente filtradas por región).
projects::zones() {
  local args=(compute zones list)
  case "${1:-}" in
    --region)
      core::validate_id región "${2:-}"
      args+=("--filter=region~/${2}$")
      ;;
    "") [[ -n "$GCPCTL_REGION" ]] && args+=("--filter=region~/${GCPCTL_REGION}$") ;;
    *) core::usage_error "Opción desconocida: $1" ;;
  esac
  core::ensure_project
  core::gcloud "${args[@]}" "$(core::gcloud_format 'table(name,region.basename(),status)')"
}

# --- config --------------------------------------------------------------------

# Lista las configuraciones de gcloud.
config::list() {
  core::gcloud config configurations list \
    "$(core::gcloud_format 'table(is_active,name,properties.core.account,properties.core.project,properties.compute.region)')"
}

# Muestra las propiedades de la configuración activa.
config::show() {
  if core::is_table; then
    core::gcloud config list
  else
    core::gcloud config list "$(core::gcloud_format)"
  fi
}

# Activa una configuración existente.
config::activate() {
  core::validate_id "NOMBRE" "${1:-}"
  registry::confirm_write "gcloud config configurations activate $1"
  core::gcloud config configurations activate "$1"
}

# Crea una configuración sin activarla.
config::create() {
  core::validate_id "NOMBRE" "${1:-}"
  registry::confirm_write "gcloud config configurations create $1"
  core::gcloud config configurations create "$1" --no-activate
}

# Fija una propiedad en la configuración activa.
config::set() {
  core::validate_id "CLAVE" "${1:-}"
  [[ -n "${2:-}" ]] || core::usage_error "Falta el valor." "Uso: gcpctl config set <CLAVE> <VALOR>"
  registry::confirm_write "gcloud config set $1 $2"
  core::gcloud config set "$1" "$2"
}

# Elimina una propiedad de la configuración activa.
config::unset() {
  core::validate_id "CLAVE" "${1:-}"
  registry::confirm_write "gcloud config unset $1"
  core::gcloud config unset "$1"
}
