#!/usr/bin/env bash
# lib/bigquery.sh — Operaciones de lectura de BigQuery mediante 'bq'.

registry::module bigquery "BigQuery: datasets, tablas y jobs" "bigquery.googleapis.com" "bq"
registry::alias bq bigquery
registry::action bigquery datasets read "Lista los datasets del proyecto" "[--limit N]"
registry::action bigquery dataset read "Muestra la información de un dataset" "<DATASET>" "dataset"
registry::action bigquery tables read "Lista las tablas de un dataset" "<DATASET> [--limit N]" "dataset"
registry::action bigquery show read "Información y esquema de una tabla" "<DATASET.TABLA>" "table"
registry::action bigquery jobs read "Lista los jobs recientes" "[--limit N] [--all-users]"

# Normaliza un dataset a 'proyecto:dataset'. Acepta ds, proj:ds y proj.ds.
bigquery::_dataset_ref() {
  local ref="$1"
  core::validate_id "DATASET" "$ref"
  if [[ "$ref" == *:* ]]; then
    printf '%s' "$ref"
  elif [[ "$ref" == *.* ]]; then
    printf '%s:%s' "${ref%%.*}" "${ref#*.}"
  else
    printf '%s:%s' "$CORE_PROJECT" "$ref"
  fi
}

# Normaliza una tabla a 'proyecto:dataset.tabla'. Acepta ds.t, proj:ds.t y proj.ds.t.
bigquery::_table_ref() {
  local ref="$1" dots
  core::validate_id "DATASET.TABLA" "$ref"
  if [[ "$ref" == *:* ]]; then
    printf '%s' "$ref"
    return
  fi
  dots="${ref//[^.]/}"
  case "${#dots}" in
    1) printf '%s:%s' "$CORE_PROJECT" "$ref" ;;
    2) printf '%s:%s' "${ref%%.*}" "${ref#*.}" ;;
    *) core::usage_error "Referencia de tabla no válida: '${ref}'." "Formato: DATASET.TABLA o PROYECTO:DATASET.TABLA" ;;
  esac
}

# Parsea '--limit N' y deja el valor en _BQ_LIMIT; el resto queda en _BQ_REST.
bigquery::_parse_limit() {
  _BQ_LIMIT=1000 _BQ_REST=()
  while (($#)); do
    case "$1" in
      --limit | -n)
        core::validate_int --limit "${2:-}"
        _BQ_LIMIT="$2"
        shift 2
        ;;
      *)
        _BQ_REST+=("$1")
        shift
        ;;
    esac
  done
}

# Lista los datasets del proyecto.
bigquery::datasets() {
  bigquery::_parse_limit "$@"
  ((${#_BQ_REST[@]} == 0)) || core::usage_error "Argumento inesperado: ${_BQ_REST[0]}"
  core::ensure_project
  core::bq ls --datasets "--max_results=${_BQ_LIMIT}" "${CORE_PROJECT}:"
}

# Muestra la información de un dataset.
bigquery::dataset() {
  core::ensure_project
  local ref
  ref="$(bigquery::_dataset_ref "${1:-}")"
  core::bq show "$ref"
}

# Lista las tablas de un dataset.
bigquery::tables() {
  bigquery::_parse_limit "$@"
  ((${#_BQ_REST[@]} == 1)) || core::usage_error "Indica un único dataset." "Uso: gcpctl bigquery tables <DATASET> [--limit N]"
  core::ensure_project
  local ref
  ref="$(bigquery::_dataset_ref "${_BQ_REST[0]}")"
  core::bq ls "--max_results=${_BQ_LIMIT}" "$ref"
}

# Resumen legible (jq) de la salida JSON de 'bq show' para una tabla.
bigquery::_table_summary() {
  jq -r '
    def ts: if . == null then "-" else (tonumber / 1000 | floor | todate) end;
    def fields(p): .[] | (p + .name) as $n
      | "  \($n)\t\(.type)\t\(.mode // "NULLABLE")\t\(.description // "")",
        (if .fields then (.fields | fields($n + ".")) else empty end);
    "Tabla:        \(.tableReference.projectId):\(.tableReference.datasetId).\(.tableReference.tableId)",
    "Tipo:         \(.type // "-")",
    "Ubicación:    \(.location // "-")",
    "Creada:       \(.creationTime | ts)",
    "Modificada:   \(.lastModifiedTime | ts)",
    "Caduca:       \(.expirationTime | ts)",
    "Filas:        \(.numRows // "-")",
    "Tamaño:       \(((.numBytes // "0") | tonumber) / 1048576 * 100 | floor / 100) MiB",
    "Partición:    \((.timePartitioning // .rangePartitioning) | if . == null then "-" else tojson end)",
    "Clustering:   \((.clustering.fields // []) | if length == 0 then "-" else join(", ") end)",
    "Etiquetas:    \((.labels // {}) | to_entries | map("\(.key)=\(.value)") | if length == 0 then "-" else join(", ") end)",
    "Descripción:  \(.description // "-")",
    (if .view.query then "", "Consulta de la vista:", .view.query else empty end),
    "",
    "Esquema:",
    ((.schema.fields // []) | fields(""))
  '
}

# Muestra información y esquema de una tabla.
bigquery::show() {
  [[ $# -eq 1 ]] || core::usage_error "Indica una tabla." "Uso: gcpctl bigquery show <DATASET.TABLA>"
  core::ensure_project
  local ref json
  ref="$(bigquery::_table_ref "$1")"
  if core::wants_summary; then
    json="$(GCPCTL_FORMAT=json core::bq show "$ref")"
    bigquery::_table_summary <<<"$json" | core::columns
  else
    core::bq show "$ref"
  fi
}

# Lista los jobs recientes (propios, o de todos los usuarios con --all-users).
bigquery::jobs() {
  local limit=25 all=()
  while (($#)); do
    case "$1" in
      --limit | -n)
        core::validate_int --limit "${2:-}"
        limit="$2"
        shift 2
        ;;
      --all-users | -a)
        all=(--all)
        shift
        ;;
      *) core::usage_error "Opción desconocida: $1" "Uso: gcpctl bigquery jobs [--limit N] [--all-users]" ;;
    esac
  done
  core::ensure_project
  core::bq ls --jobs "${all[@]}" "--max_results=${limit}" "${CORE_PROJECT}"
}
