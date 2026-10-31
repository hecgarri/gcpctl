#!/usr/bin/env bash
# lib/cloudrun.sh — Cloud Run: servicios (detalles, estado, revisiones) y
# jobs (detalles, ejecuciones y lanzamiento).

registry::module cloudrun "Cloud Run: servicios, revisiones, jobs y ejecuciones" "run.googleapis.com"
registry::alias run cloudrun
registry::action cloudrun list read "Lista los servicios (todas las regiones salvo --region)" "[--region REGIÓN]"
registry::action cloudrun describe read "Detalles completos de un servicio" "<SERVICIO> [--region REGIÓN]" "run_service"
registry::action cloudrun status read "Estado, URL, condiciones y tráfico de un servicio" "<SERVICIO> [--region REGIÓN]" "run_service"
registry::action cloudrun revisions read "Revisiones de un servicio" "<SERVICIO> [--region REGIÓN]" "run_service"
registry::action cloudrun jobs read "Lista los jobs (todas las regiones salvo --region)" "[--region REGIÓN]"
registry::action cloudrun job read "Estado de un job y su última ejecución" "<JOB> [--region REGIÓN]" "run_job"
registry::action cloudrun executions read "Ejecuciones de un job (más recientes primero)" "<JOB> [--limit N] [--region REGIÓN]" "run_job"
registry::action cloudrun execution read "Detalle de una ejecución" "<EJECUCIÓN> [--region REGIÓN]" "run_job run_execution"
registry::action cloudrun execute write "Lanza una ejecución de un job" "<JOB> [--wait] [--region REGIÓN]" "run_job"

# Resuelve la región de un servicio o job: --region > run/region > búsqueda por nombre.
# Uso: cloudrun::_region <nombre> [services|jobs]
cloudrun::_region() {
  local name="$1" kind="${2:-services}" region="${GCPCTL_REGION:-${GCPCTL_LOCATION:-}}" json
  [[ -z "$region" ]] && region="$(core::gcloud_prop run/region)"
  if [[ -z "$region" ]]; then
    # shellcheck disable=SC2034  # Sobrescribe el global para esta lectura.
    local GCPCTL_DRY_RUN=0
    json="$(core::gcloud_json run "$kind" list)" || return
    region="$(jq -r --arg n "$name" '[.[] | select(.metadata.name == $n) | .metadata.labels["cloud.googleapis.com/location"] // empty] | unique | if length == 1 then .[0] else "" end' <<<"$json")"
    [[ -n "$region" ]] || core::usage_error "No se pudo determinar la región de '${name}'." "Indica --region <REGIÓN>."
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

# --- Jobs ----------------------------------------------------------------------

# Lista los jobs de Cloud Run.
cloudrun::jobs() {
  [[ $# -eq 0 ]] || core::usage_error "Argumento inesperado: $1" "Uso: gcpctl cloudrun jobs [--region REGIÓN]"
  core::ensure_project
  local args=(run jobs list)
  [[ -n "$GCPCTL_REGION" ]] && args+=("--region=${GCPCTL_REGION}")
  if core::is_table; then
    core::gcloud "${args[@]}"
  else
    core::gcloud "${args[@]}" "$(core::gcloud_format)"
  fi
}

# Estado de un job: imagen, programación de tareas y última ejecución.
cloudrun::job() {
  [[ $# -eq 1 ]] || core::usage_error "Indica un job." "Uso: gcpctl cloudrun job <JOB>"
  core::validate_id JOB "$1"
  core::ensure_project
  local region json
  region="$(cloudrun::_region "$1" jobs)"
  if ! core::wants_summary; then
    core::gcloud run jobs describe "$1" "--region=${region}" "$(core::gcloud_format yaml)"
    return
  fi
  json="$(core::gcloud_json run jobs describe "$1" "--region=${region}")"
  jq -r '
    (.spec.template.spec.template.spec // {}) as $t |
    "Job:              \(.metadata.name)",
    "Región:           \(.metadata.labels["cloud.googleapis.com/location"] // "-")",
    "Imagen:           \(($t.containers // [])[0].image // "-")",
    "Tareas:           \(.spec.template.spec.taskCount // 1) (paralelismo \(.spec.template.spec.parallelism // "auto"))",
    "Reintentos:       \($t.maxRetries // "-")   Timeout: \($t.timeoutSeconds // "-")s",
    "Cuenta servicio:  \($t.serviceAccountName // "-")",
    "Ejecuciones:      \(.status.executionCount // 0)",
    "",
    "Última ejecución:",
    "  Nombre:         \(.status.latestCreatedExecution.name // "-")",
    "  Resultado:      \(.status.latestCreatedExecution.completionStatus // "-")",
    "  Creada:         \(.status.latestCreatedExecution.creationTimestamp // "-")",
    "  Finalizada:     \(.status.latestCreatedExecution.completionTimestamp // "-")",
    "",
    "Condiciones:",
    ((.status.conditions // [])[] | "  \(.type)\t\(.status)\t\(.reason // "")\t\(.message // "")")
  ' <<<"$json" | core::columns
}

# Lista las ejecuciones de un job.
cloudrun::executions() {
  local job="" limit=20
  while (($#)); do
    case "$1" in
      --limit)
        core::validate_int --limit "${2:-}"
        limit="$2"
        shift 2
        ;;
      -*) core::usage_error "Opción desconocida: $1" ;;
      *)
        [[ -z "$job" ]] || core::usage_error "Argumento inesperado: $1"
        job="$1"
        shift
        ;;
    esac
  done
  core::validate_id JOB "$job"
  core::ensure_project
  local region
  region="$(cloudrun::_region "$job" jobs)"
  local args=(run jobs executions list "--job=${job}" "--region=${region}" "--limit=${limit}")
  if core::is_table; then
    core::gcloud "${args[@]}"
  else
    core::gcloud "${args[@]}" "$(core::gcloud_format)"
  fi
}

# Detalle de una ejecución. Acepta 'JOB EJECUCIÓN' (TUI) o sólo 'EJECUCIÓN'.
cloudrun::execution() {
  local job="" execution
  case $# in
    1) execution="$1" ;;
    2) job="$1" execution="$2" ;;
    *) core::usage_error "Indica una ejecución." "Uso: gcpctl cloudrun execution <EJECUCIÓN> [--region REGIÓN]" ;;
  esac
  core::validate_id EJECUCIÓN "$execution"
  core::ensure_project
  local region
  # El nombre de una ejecución es <job>-<sufijo>: sirve para descubrir la región.
  region="$(cloudrun::_region "${job:-${execution%-*}}" jobs)"
  if core::is_table; then
    core::gcloud run jobs executions describe "$execution" "--region=${region}"
  else
    core::gcloud run jobs executions describe "$execution" "--region=${region}" "$(core::gcloud_format)"
  fi
}

# Lanza una ejecución de un job (por defecto asíncrona; --wait espera a que termine).
cloudrun::execute() {
  local job="" mode=--async
  while (($#)); do
    case "$1" in
      --wait)
        mode=--wait
        shift
        ;;
      -*) core::usage_error "Opción desconocida: $1" ;;
      *)
        [[ -z "$job" ]] || core::usage_error "Argumento inesperado: $1"
        job="$1"
        shift
        ;;
    esac
  done
  core::validate_id JOB "$job"
  core::ensure_project
  local region
  region="$(cloudrun::_region "$job" jobs)"
  registry::confirm_write "ejecutar el job ${job} (región ${region})"
  core::gcloud run jobs execute "$job" "--region=${region}" "$mode"
}
