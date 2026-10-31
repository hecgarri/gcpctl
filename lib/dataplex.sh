#!/usr/bin/env bash
# lib/dataplex.sh — Dataplex / Knowledge Catalog: DataScans, resultados de
# calidad de datos y recursos de catalogación.

registry::module dataplex "Dataplex / Knowledge Catalog: DataScans y catálogo" "dataplex.googleapis.com"
registry::alias catalog dataplex
registry::action dataplex scans read "Lista los DataScans de una ubicación" "[--location REGIÓN]"
registry::action dataplex scan read "Configuración completa de un DataScan" "<SCAN> [--location REGIÓN]" "datascan"
registry::action dataplex jobs read "Ejecuciones (jobs) de un DataScan" "<SCAN> [--limit N] [--location REGIÓN]" "datascan"
registry::action dataplex result read "Resultado de una ejecución (por defecto la última)" "<SCAN> [JOB] [--location REGIÓN]" "datascan datascan_job?"
registry::action dataplex entry-groups read "Lista los grupos de entradas del catálogo" "[--location REGIÓN|global]"
registry::action dataplex entries read "Lista las entradas de un grupo" "<ENTRY_GROUP> [--location REGIÓN|global]" "entry_group"
registry::action dataplex search read "Busca entradas en el catálogo" "<CONSULTA> [--limit N]" "text:Texto a buscar"

# Ubicación de Dataplex: --location > --region > compute/region.
dataplex::_location() { core::resolve_location "Dataplex" compute/region; }

# Lista los DataScans.
dataplex::scans() {
  [[ $# -eq 0 ]] || core::usage_error "Argumento inesperado: $1" "Uso: gcpctl dataplex scans [--location REGIÓN]"
  core::ensure_project
  local location
  location="$(dataplex::_location)"
  core::gcloud dataplex datascans list "--location=${location}" \
    "$(core::gcloud_format 'table(name.basename():label=SCAN,type,state,data.resource.basename():label=RESOURCE,executionStatus.latestJobEndTime:label=LAST_JOB_END)')"
}

# Muestra la configuración completa de un DataScan.
dataplex::scan() {
  [[ $# -eq 1 ]] || core::usage_error "Indica un DataScan." "Uso: gcpctl dataplex scan <SCAN>"
  core::validate_id SCAN "$1"
  core::ensure_project
  local location fmt
  location="$(dataplex::_location)"
  fmt="$(core::gcloud_format yaml)"
  core::gcloud dataplex datascans describe "$1" "--location=${location}" --view=FULL "$fmt"
}

# Lista las ejecuciones de un DataScan (más recientes primero).
dataplex::jobs() {
  local scan="" limit=20
  while (($#)); do
    case "$1" in
      --limit)
        core::validate_int --limit "${2:-}"
        limit="$2"
        shift 2
        ;;
      -*) core::usage_error "Opción desconocida: $1" ;;
      *)
        [[ -z "$scan" ]] || core::usage_error "Argumento inesperado: $1"
        scan="$1"
        shift
        ;;
    esac
  done
  core::validate_id SCAN "$scan"
  core::ensure_project
  local location
  location="$(dataplex::_location)"
  core::gcloud dataplex datascans jobs list "--datascan=${scan}" "--location=${location}" \
    --sort-by=~startTime "--limit=${limit}" \
    "$(core::gcloud_format 'table(name.basename():label=JOB,type,state,startTime,endTime)')"
}

# Imprime el ID de la ejecución más reciente de un DataScan.
dataplex::_latest_job() {
  # shellcheck disable=SC2034  # Sobrescribe el global para esta lectura.
  local GCPCTL_DRY_RUN=0
  core::gcloud dataplex datascans jobs list "--datascan=$1" "--location=$2" \
    --sort-by=~startTime --limit=1 --format='value(name.basename())'
}

# Resumen legible del resultado de calidad de datos (jq).
dataplex::_dq_summary() {
  jq -r '
    def pct: if . == null then "-" else ((. * 10000 | round) / 100 | tostring) + "%" end;
    "Job:          \(.name | split("/") | last)",
    "Tipo:         \(.type // "-")",
    "Estado:       \(.state // "-")",
    "Inicio:       \(.startTime // "-")",
    "Fin:          \(.endTime // "-")",
    (if .message then "Mensaje:      \(.message)" else empty end),
    (if .dataQualityResult then
      (.dataQualityResult as $r |
        "Resultado:    \(if $r.passed then "SUPERADO" else "NO SUPERADO" end)",
        "Puntuación:   \($r.score // "-")",
        "Filas:        \($r.rowCount // "-")",
        "",
        "Dimensiones:",
        (($r.dimensions // [])[] | "  \(.dimension.name // .dimension // "-")\t\(if .passed then "OK" else "FALLO" end)\t\(.score // "-")"),
        "",
        "Reglas:",
        "  REGLA\tCOLUMNA\tDIMENSIÓN\tESTADO\tEVALUADAS\tSUPERADAS\tRATIO",
        (($r.rules // [])[] |
          "  \(.rule.name // .rule.ruleType // "-")\t\(.rule.column // "-")\t\(.rule.dimension // "-")\t\(if .passed then "OK" else "FALLO" end)\t\(.evaluatedCount // "-")\t\(.passedCount // "-")\t\(.passRatio | pct)"))
    elif .dataProfileResult then
      "", "Perfilado: \(.dataProfileResult.rowCount // "-") filas analizadas (usa --format json para el detalle).",
      ((.dataProfileResult.profile.fields // [])[] | "  \(.name)\t\(.type)\tnulos=\(.profile.nullRatio | pct)\tdistintos=\(.profile.distinctRatio | pct)")
    else empty end)
  '
}

# Muestra el resultado de una ejecución; si no se indica JOB usa la más reciente.
dataplex::result() {
  local scan="${1:-}" job="${2:-}"
  [[ $# -le 2 ]] || core::usage_error "Demasiados argumentos." "Uso: gcpctl dataplex result <SCAN> [JOB]"
  core::validate_id SCAN "$scan"
  core::ensure_project
  local location json
  location="$(dataplex::_location)"
  if [[ -z "$job" ]]; then
    job="$(dataplex::_latest_job "$scan" "$location")"
    [[ -n "$job" ]] || core::die "El DataScan '${scan}' no tiene ejecuciones."
    core::info "Última ejecución: ${job}"
  fi
  core::validate_id JOB "$job"
  if core::wants_summary; then
    json="$(core::gcloud_json dataplex datascans jobs describe "$job" "--datascan=${scan}" "--location=${location}" --view=FULL)"
    dataplex::_dq_summary <<<"$json" | core::columns
  else
    core::gcloud dataplex datascans jobs describe "$job" "--datascan=${scan}" "--location=${location}" \
      --view=FULL "$(core::gcloud_format yaml)"
  fi
}

# Lista los grupos de entradas del catálogo.
dataplex::entry_groups() {
  [[ $# -eq 0 ]] || core::usage_error "Argumento inesperado: $1"
  core::ensure_project
  local location
  location="$(dataplex::_location)"
  core::gcloud dataplex entry-groups list "--location=${location}" \
    "$(core::gcloud_format 'table(name.basename():label=ENTRY_GROUP,displayName,createTime,updateTime)')"
}

# Lista las entradas de un grupo de entradas.
dataplex::entries() {
  [[ $# -eq 1 ]] || core::usage_error "Indica un grupo de entradas." "Uso: gcpctl dataplex entries <ENTRY_GROUP>"
  core::validate_id ENTRY_GROUP "$1"
  core::ensure_project
  local location
  location="$(dataplex::_location)"
  core::gcloud dataplex entries list "--entry-group=$1" "--location=${location}" \
    "$(core::gcloud_format 'table(name.basename():label=ENTRY,entryType.basename():label=TYPE,fullyQualifiedName:label=FQN)')"
}

# Busca entradas en Knowledge Catalog (la consulta se pasa como un único argumento).
dataplex::search() {
  local query="" limit=50
  while (($#)); do
    case "$1" in
      --limit)
        core::validate_int --limit "${2:-}"
        limit="$2"
        shift 2
        ;;
      *)
        query+="${query:+ }$1"
        shift
        ;;
    esac
  done
  [[ -n "$query" ]] || core::usage_error "Falta la consulta." "Uso: gcpctl dataplex search <CONSULTA>"
  core::ensure_project
  core::gcloud dataplex entries search "$query" "--limit=${limit}" \
    "$(core::gcloud_format 'table(dataplexEntry.entrySource.displayName:label=NAME,dataplexEntry.entrySource.system:label=SYSTEM,dataplexEntry.entryType.basename():label=TYPE,dataplexEntry.fullyQualifiedName:label=FQN)')"
}
