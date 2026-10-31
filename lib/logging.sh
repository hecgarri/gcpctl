#!/usr/bin/env bash
# lib/logging.sh — Cloud Logging: lectura de logs con filtros de severidad,
# servicio, texto y antigüedad.

registry::module logging "Cloud Logging: lectura y errores recientes" "logging.googleapis.com"
registry::alias logs logging
registry::action logging read read "Lee logs del proyecto con filtros" \
  "[--severity NIVEL] [--service SERVICIO] [--label CLAVE=VALOR] [--text TEXTO] [--filter EXPR] [--freshness 1h] [--limit N] [--asc]"
registry::action logging errors read "Errores recientes (severity>=ERROR)" "[--service SERVICIO] [--freshness 1d] [--limit N]" "logging_service?"
registry::action logging services read "Alias de servicio admitidos por --service"

# Severidades válidas de Cloud Logging.
readonly LOGGING_SEVERITIES="DEFAULT DEBUG INFO NOTICE WARNING ERROR CRITICAL ALERT EMERGENCY"

# Alias de servicio -> fragmento de filtro.
declare -gA LOGGING_SERVICE_FILTERS=(
  [run]='resource.type="cloud_run_revision"'
  ['run-job']='resource.type="cloud_run_job"'
  [composer]='resource.type="cloud_composer_environment"'
  [compute]='resource.type="gce_instance"'
  [bigquery]='(resource.type="bigquery_resource" OR resource.type="bigquery_project" OR resource.type="bigquery_dataset")'
  [dataplex]='protoPayload.serviceName="dataplex.googleapis.com"'
  [functions]='resource.type="cloud_function"'
  [gke]='resource.type="k8s_container"'
  [dataflow]='resource.type="dataflow_step"'
  [sql]='resource.type="cloudsql_database"'
  [gcs]='resource.type="gcs_bucket"'
  [iam]='protoPayload.serviceName="iam.googleapis.com"'
  [scheduler]='resource.type="cloud_scheduler_job"'
  [build]='resource.type="build"'
  [pubsub]='(resource.type="pubsub_topic" OR resource.type="pubsub_subscription")'
  [artifacts]='protoPayload.serviceName="artifactregistry.googleapis.com"'
  [secrets]='protoPayload.serviceName="secretmanager.googleapis.com"'
)

# Traduce --service a un filtro: alias conocido, 'xxx.googleapis.com' o resource.type literal.
logging::_service_filter() {
  local svc="$1"
  case "$svc" in
    cloudrun) svc=run ;;
    gce) svc=compute ;;
    bq) svc=bigquery ;;
  esac
  if [[ -n "${LOGGING_SERVICE_FILTERS[$svc]:-}" ]]; then
    printf '%s' "${LOGGING_SERVICE_FILTERS[$svc]}"
  elif [[ "$svc" =~ ^[a-z0-9-]+\.googleapis\.com$ ]]; then
    printf 'protoPayload.serviceName=%s' "$(core::filter_quote "$svc")"
  elif [[ "$svc" =~ ^[a-z0-9_./-]+$ ]]; then
    printf 'resource.type=%s' "$(core::filter_quote "$svc")"
  else
    core::usage_error "Servicio no válido: '${svc}'." "Consulta 'gcpctl logging services'."
  fi
}

# Construye el filtro y ejecuta la lectura. Se comparte entre 'read' y 'errors'.
# Uso: logging::_query <freshness_por_defecto> <severidad_por_defecto> [opciones...]
logging::_query() {
  local freshness="$1" severity="$2" limit=50 order=desc parts=()
  shift 2
  while (($#)); do
    case "$1" in
      --severity)
        core::need_value "$1" "${2:-}"
        severity="${2^^}"
        shift 2
        ;;
      --service)
        core::need_value "$1" "${2:-}"
        parts+=("$(logging::_service_filter "$2")")
        shift 2
        ;;
      --label)
        core::need_value "$1" "${2:-}"
        [[ "$2" =~ ^([A-Za-z0-9_./-]+)=(.*)$ ]] || core::usage_error "--label espera CLAVE=VALOR."
        parts+=("resource.labels.${BASH_REMATCH[1]}=$(core::filter_quote "${BASH_REMATCH[2]}")")
        shift 2
        ;;
      --text)
        core::need_value "$1" "${2:-}"
        parts+=("$(core::filter_quote "$2")")
        shift 2
        ;;
      --filter)
        core::need_value "$1" "${2:-}"
        parts+=("($2)")
        shift 2
        ;;
      --freshness)
        [[ "${2:-}" =~ ^[0-9]+[smhdw]$ ]] || core::usage_error "--freshness espera un valor como 30m, 1h, 2d."
        freshness="$2"
        shift 2
        ;;
      --limit)
        core::validate_int --limit "${2:-}"
        limit="$2"
        shift 2
        ;;
      --asc)
        order=asc
        shift
        ;;
      *) core::usage_error "Opción desconocida: $1" "Uso: gcpctl logging read --help" ;;
    esac
  done
  if [[ -n "$severity" ]]; then
    [[ " $LOGGING_SEVERITIES " == *" $severity "* ]] || core::usage_error "Severidad no válida: '${severity}'." "Valores: ${LOGGING_SEVERITIES}"
    parts=("severity>=${severity}" "${parts[@]}")
  fi
  local filter="" p
  for p in "${parts[@]}"; do filter+="${filter:+ AND }${p}"; done
  core::ensure_project
  core::debug "filtro: ${filter:-(ninguno)}"

  local args=(logging read "--freshness=${freshness}" "--limit=${limit}" "--order=${order}")
  [[ -n "$filter" ]] && args=(logging read "$filter" "${args[@]:2}")
  if core::wants_summary; then
    local json
    json="$(core::gcloud_json "${args[@]}")"
    logging::_render <<<"$json"
  else
    core::gcloud "${args[@]}" "$(core::gcloud_format 'table(timestamp,severity,resource.type,textPayload)')"
  fi
}

# Renderiza entradas de log (JSON) en líneas legibles de ancho acotado.
logging::_render() {
  local cols="${COLUMNS:-}"
  [[ -z "$cols" ]] && cols="$(tput cols 2>/dev/null || echo 160)"
  jq -r --argjson w "$((cols > 80 ? cols - 54 : 80))" '
    if length == 0 then "(sin entradas en el periodo indicado)" else .[] |
    ( .textPayload // .jsonPayload.message // .jsonPayload.msg // .protoPayload.status.message
      // (if .protoPayload then "\(.protoPayload.methodName // "") \(.protoPayload.resourceName // "")" else null end)
      // (.jsonPayload | if . then tojson else null end) // "" ) as $m
    | "\(.timestamp[0:19] | sub("T"; " "))  \((.severity // "DEFAULT") | .[0:8] | . + (" " * (8 - length)))  \((.resource.type // "-") | .[0:22] | . + (" " * (22 - length)))  \($m | gsub("\\s+"; " ") | .[0:$w])"
    end'
}

# Lee logs del proyecto (por defecto última hora, sin filtro de severidad).
logging::read() { logging::_query 1h "" "$@"; }

# Errores recientes (por defecto último día, severity>=ERROR). Admite un
# servicio como argumento posicional para la TUI: 'gcpctl logging errors run'.
logging::errors() {
  if [[ $# -ge 1 && "$1" != -* ]]; then
    local svc="$1"
    shift
    set -- --service "$svc" "$@"
  fi
  logging::_query 1d ERROR "$@"
}

# Muestra los alias de servicio disponibles para --service.
logging::services() {
  local k
  for k in $(printf '%s\n' "${!LOGGING_SERVICE_FILTERS[@]}" | sort); do
    printf '%-10s %s\n' "$k" "${LOGGING_SERVICE_FILTERS[$k]}"
  done
  printf '\nTambién se acepta un nombre de API (p. ej. pubsub.googleapis.com) o un resource.type literal.\n'
}
