#!/usr/bin/env bash
# lib/cloudrun.sh — Cloud Run: servicios, detalles, estado y revisiones.

registry::module cloudrun "Cloud Run: servicios y revisiones" "run.googleapis.com"
registry::alias run cloudrun
registry::action cloudrun list read "Lista los servicios (todas las regiones salvo --region)" "[--region REGIÓN]"
registry::action cloudrun describe read "Detalles completos de un servicio" "<SERVICIO> [--region REGIÓN]" "run_service"
registry::action cloudrun status read "Estado, URL, condiciones y tráfico de un servicio" "<SERVICIO> [--region REGIÓN]" "run_service"
registry::action cloudrun revisions read "Revisiones de un servicio" "<SERVICIO> [--region REGIÓN]" "run_service"

# Resuelve la región de un servicio: --region > run/region > búsqueda por nombre.
cloudrun::_region() {
  local name="$1" region="${GCPCTL_REGION:-${GCPCTL_LOCATION:-}}" json
  [[ -z "$region" ]] && region="$(core::gcloud_prop run/region)"
  if [[ -z "$region" ]]; then
    # shellcheck disable=SC2034  # Sobrescribe el global para esta lectura.
    local GCPCTL_DRY_RUN=0
    json="$(core::gcloud_json run services list "--filter=metadata.name=${name}")" || return
    region="$(jq -r '[.[].metadata.labels["cloud.googleapis.com/location"] // empty] | unique | if length == 1 then .[0] else "" end' <<<"$json")"
    [[ -n "$region" ]] || core::usage_error "No se pudo determinar la región del servicio '${name}'." "Indica --region <REGIÓN>."
  fi
  core::validate_id región "$region"
  printf '%s' "$region"
}

# Lista los servicios de Cloud Run.
cloudrun::list() {
  [[ $# -eq 0 ]] || core::usage_error "Argumento inesperado: $1" "Uso: gcpctl cloudrun list [--region REGIÓN]"
  core::ensure_project
  local args=(run services list)
  [[ -n "$GCPCTL_REGION" ]] && args+=("--region=${GCPCTL_REGION}")
  if core::is_table; then
    core::gcloud "${args[@]}"
  else
    core::gcloud "${args[@]}" "$(core::gcloud_format)"
  fi
}

# Detalles completos de un servicio.
cloudrun::describe() {
  [[ $# -eq 1 ]] || core::usage_error "Indica un servicio." "Uso: gcpctl cloudrun describe <SERVICIO>"
  core::validate_id SERVICIO "$1"
  core::ensure_project
  local region
  region="$(cloudrun::_region "$1")"
  if core::is_table; then
    core::gcloud run services describe "$1" "--region=${region}"
  else
    core::gcloud run services describe "$1" "--region=${region}" "$(core::gcloud_format)"
  fi
}

# Estado resumido de un servicio (condiciones, URL, tráfico).
cloudrun::status() {
  [[ $# -eq 1 ]] || core::usage_error "Indica un servicio." "Uso: gcpctl cloudrun status <SERVICIO>"
  core::validate_id SERVICIO "$1"
  core::ensure_project
  local region json
  region="$(cloudrun::_region "$1")"
  if ! core::wants_summary; then
    core::gcloud run services describe "$1" "--region=${region}" \
      "$(core::gcloud_format 'table(metadata.name,status.url,status.latestReadyRevisionName,status.conditions)')"
    return
  fi
  json="$(core::gcloud_json run services describe "$1" "--region=${region}")"
  jq -r '
    "Servicio:     \(.metadata.name)",
    "Región:       \(.metadata.labels["cloud.googleapis.com/location"] // "-")",
    "URL:          \(.status.url // "-")",
    "Revisión:     \(.status.latestReadyRevisionName // "-") (creada: \(.status.latestCreatedRevisionName // "-"))",
    "Actualizado:  \(.metadata.annotations["serving.knative.dev/lastModifier"] // "-")",
    "",
    "Condiciones:",
    ((.status.conditions // [])[] | "  \(.type)\t\(.status)\t\(.reason // "")\t\(.message // "")"),
    "",
    "Tráfico:",
    ((.status.traffic // [])[] | "  \(.revisionName // "latest")\t\(.percent // 0)%\t\(.tag // "")")
  ' <<<"$json" | core::columns
}

# Lista las revisiones de un servicio.
cloudrun::revisions() {
  [[ $# -eq 1 ]] || core::usage_error "Indica un servicio." "Uso: gcpctl cloudrun revisions <SERVICIO>"
  core::validate_id SERVICIO "$1"
  core::ensure_project
  local region
  region="$(cloudrun::_region "$1")"
  if core::is_table; then
    core::gcloud run revisions list "--service=$1" "--region=${region}"
  else
    core::gcloud run revisions list "--service=$1" "--region=${region}" "$(core::gcloud_format)"
  fi
}
