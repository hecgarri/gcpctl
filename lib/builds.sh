#!/usr/bin/env bash
# lib/builds.sh — Cloud Build: compilaciones, logs y triggers (sólo lectura).

registry::module builds "Cloud Build: compilaciones, logs y triggers" "cloudbuild.googleapis.com"
registry::alias cloudbuild builds
registry::alias build builds
registry::action builds list read "Compilaciones recientes (global salvo --region)" "[--ongoing] [--limit N] [--region REGIÓN]"
registry::action builds describe read "Detalle de una compilación" "<BUILD_ID> [--region REGIÓN]" "build"
registry::action builds log read "Log de una compilación" "<BUILD_ID> [--region REGIÓN]" "build"
registry::action builds triggers read "Lista los triggers" "[--region REGIÓN]"

# Añade --region si se indicó (Cloud Build usa 'global' por defecto).
builds::_region_args() {
  _BUILD_REGION=()
  [[ -n "${GCPCTL_REGION:-${GCPCTL_LOCATION:-}}" ]] && _BUILD_REGION=("--region=${GCPCTL_REGION:-$GCPCTL_LOCATION}")
  return 0
}

# Lista compilaciones recientes.
builds::list() {
  local limit=20 args=(builds list)
  while (($#)); do
    case "$1" in
      --ongoing)
        args+=(--ongoing)
        shift
        ;;
      --limit)
        core::validate_int --limit "${2:-}"
        limit="$2"
        shift 2
        ;;
      *) core::usage_error "Opción desconocida: $1" "Uso: gcpctl builds list [--ongoing] [--limit N]" ;;
    esac
  done
  core::ensure_project
  builds::_region_args
  core::gcloud "${args[@]}" "${_BUILD_REGION[@]}" "--limit=${limit}" \
    "$(core::gcloud_format 'table(id,status,createTime.date(),duration(start=startTime,end=finishTime,precision=0,calendar=false,undefined="-"):label=DURATION,substitutions.TRIGGER_NAME:label=TRIGGER,source.repoSource.repoName.yesno(no=""):label=REPO,images.list():label=IMAGES)')"
}

# Detalle de una compilación.
builds::describe() {
  [[ $# -eq 1 ]] || core::usage_error "Indica un BUILD_ID." "Uso: gcpctl builds describe <BUILD_ID>"
  core::validate_id BUILD_ID "$1"
  core::ensure_project
  builds::_region_args
  if core::is_table; then
    core::gcloud builds describe "$1" "${_BUILD_REGION[@]}" \
      --format='yaml(id,status,statusDetail,createTime,startTime,finishTime,logUrl,substitutions,steps[].name,steps[].status,images,failureInfo)'
  else
    core::gcloud builds describe "$1" "${_BUILD_REGION[@]}" "$(core::gcloud_format)"
  fi
}

# Muestra el log de una compilación.
builds::log() {
  [[ $# -eq 1 ]] || core::usage_error "Indica un BUILD_ID." "Uso: gcpctl builds log <BUILD_ID>"
  core::validate_id BUILD_ID "$1"
  core::ensure_project
  builds::_region_args
  core::gcloud builds log "$1" "${_BUILD_REGION[@]}"
}

# Lista los triggers.
builds::triggers() {
  [[ $# -eq 0 ]] || core::usage_error "Argumento inesperado: $1"
  core::ensure_project
  builds::_region_args
  core::gcloud builds triggers list "${_BUILD_REGION[@]}" \
    "$(core::gcloud_format 'table(name,disabled.yesno(yes="deshabilitado",no="activo"):label=STATE,github.name.yesno(no=""):label=GITHUB_REPO,triggerTemplate.branchName:label=BRANCH,github.push.branch:label=PUSH_BRANCH,filename:label=CONFIG)')"
}
