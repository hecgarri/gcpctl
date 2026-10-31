#!/usr/bin/env bash
# lib/storage.sh — Cloud Storage: buckets y objetos (sólo lectura).

registry::module storage "Cloud Storage: buckets y objetos" "storage.googleapis.com"
registry::alias gcs storage
registry::action storage buckets read "Lista los buckets del proyecto"
registry::action storage bucket read "Configuración de un bucket" "<BUCKET>" "bucket"
registry::action storage ls read "Lista objetos de un bucket o prefijo" "<gs://BUCKET[/PREFIJO]> [--recursive]" "bucket"
registry::action storage du read "Tamaño total de un bucket o prefijo" "<gs://BUCKET[/PREFIJO]>" "bucket"

# Normaliza 'bucket', 'bucket/prefijo' o 'gs://bucket/prefijo' a una URL gs://.
storage::_url() {
  local ref="${1#gs://}"
  core::validate_id "BUCKET" "$ref"
  printf 'gs://%s' "$ref"
}

# Lista los buckets.
storage::buckets() {
  [[ $# -eq 0 ]] || core::usage_error "Argumento inesperado: $1"
  core::ensure_project
  core::gcloud storage buckets list \
    "$(core::gcloud_format 'table(name,location,location_type:label=LOCATION_TYPE,default_storage_class:label=CLASS,public_access_prevention:label=PUBLIC_ACCESS_PREVENTION,uniform_bucket_level_access:label=UNIFORM_ACCESS,creation_time.date():label=CREATED)')"
}

# Configuración de un bucket.
storage::bucket() {
  [[ $# -eq 1 ]] || core::usage_error "Indica un bucket." "Uso: gcpctl storage bucket <BUCKET>"
  local url
  url="$(storage::_url "$1")"
  core::ensure_project
  core::gcloud storage buckets describe "${url%%/}" "$(core::gcloud_format yaml)"
}

# Lista objetos. En modo tabla usa el listado largo con tamaños legibles.
storage::ls() {
  local path="" recursive=()
  while (($#)); do
    case "$1" in
      --recursive | -r)
        recursive=(--recursive)
        shift
        ;;
      -*) core::usage_error "Opción desconocida: $1" ;;
      *)
        [[ -z "$path" ]] || core::usage_error "Argumento inesperado: $1"
        path="$1"
        shift
        ;;
    esac
  done
  [[ -n "$path" ]] || core::usage_error "Indica un bucket o prefijo." "Uso: gcpctl storage ls gs://BUCKET[/PREFIJO]"
  local url
  url="$(storage::_url "$path")"
  core::ensure_project
  # Un bucket sin barra final lista su raíz.
  [[ "${url#gs://}" == */* ]] || url+="/"
  local args=(storage ls "$url" "${recursive[@]}")
  case "$GCPCTL_FORMAT" in
    json) args+=(--json) ;;
    table) args+=(--long --readable-sizes) ;;
    *) args+=(--long) ;;
  esac
  core::gcloud "${args[@]}"
}

# Tamaño total (resumen) de un bucket o prefijo.
storage::du() {
  [[ $# -eq 1 ]] || core::usage_error "Indica un bucket o prefijo." "Uso: gcpctl storage du gs://BUCKET[/PREFIJO]"
  local url
  url="$(storage::_url "$1")"
  core::ensure_project
  core::gcloud storage du "$url" --summarize --readable-sizes
}
