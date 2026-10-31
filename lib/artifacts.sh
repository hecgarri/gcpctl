#!/usr/bin/env bash
# lib/artifacts.sh — Artifact Registry: repositorios, imágenes, paquetes y versiones.

registry::module artifacts "Artifact Registry: repositorios, imágenes y paquetes" "artifactregistry.googleapis.com"
registry::alias ar artifacts
registry::action artifacts repos read "Lista los repositorios de una ubicación" "[--location REGIÓN]"
registry::action artifacts repo read "Detalle de un repositorio" "<REPO> [--location REGIÓN]" "ar_repo"
registry::action artifacts images read "Imágenes Docker de un repositorio (con tags)" "<REPO> [--limit N] [--location REGIÓN]" "ar_repo"
registry::action artifacts packages read "Paquetes de un repositorio (cualquier formato)" "<REPO> [--location REGIÓN]" "ar_repo"
registry::action artifacts versions read "Versiones de un paquete" "<REPO> <PAQUETE> [--limit N] [--location REGIÓN]" "ar_repo ar_package"

# Ubicación de Artifact Registry: --location > artifacts/location > run/region > compute/region.
# Se exige una ubicación porque listar en todas puede tardar varios minutos.
artifacts::_location() {
  core::resolve_location "Artifact Registry" artifacts/location run/region compute/region
}

# Parsea '<posicionales> [--limit N]'. Deja _AR_POS y _AR_LIMIT.
artifacts::_parse() {
  _AR_POS=() _AR_LIMIT=100
  while (($#)); do
    case "$1" in
      --limit)
        core::validate_int --limit "${2:-}"
        _AR_LIMIT="$2"
        shift 2
        ;;
      -*) core::usage_error "Opción desconocida: $1" ;;
      *)
        _AR_POS+=("$1")
        shift
        ;;
    esac
  done
}

# Lista los repositorios.
artifacts::repos() {
  [[ $# -eq 0 ]] || core::usage_error "Argumento inesperado: $1" "Uso: gcpctl artifacts repos [--location REGIÓN]"
  core::ensure_project
  local location
  location="$(artifacts::_location)"
  core::gcloud artifacts repositories list "--location=${location}" \
    "$(core::gcloud_format 'table(name.basename():label=REPOSITORY,format,mode,description,sizeBytes.size(zero="0",precision=3,units_out=M):label=SIZE_MB,updateTime.date())')"
}

# Detalle de un repositorio.
artifacts::repo() {
  [[ $# -eq 1 ]] || core::usage_error "Indica un repositorio." "Uso: gcpctl artifacts repo <REPO>"
  core::validate_id REPO "$1"
  core::ensure_project
  local location
  location="$(artifacts::_location)"
  core::gcloud artifacts repositories describe "$1" "--location=${location}" "$(core::gcloud_format yaml)"
}

# Lista las imágenes Docker (con tags) de un repositorio.
artifacts::images() {
  artifacts::_parse "$@"
  ((${#_AR_POS[@]} == 1)) || core::usage_error "Indica un repositorio." "Uso: gcpctl artifacts images <REPO> [--limit N]"
  core::validate_id REPO "${_AR_POS[0]}"
  core::ensure_project
  local location
  location="$(artifacts::_location)"
  core::gcloud artifacts docker images list "${location}-docker.pkg.dev/${CORE_PROJECT}/${_AR_POS[0]}" \
    --include-tags --sort-by=~UPDATE_TIME "--limit=${_AR_LIMIT}" \
    "$(core::gcloud_format 'table(package.basename():label=IMAGE,version.basename().slice(7:19).join(""):label=DIGEST,tags.list():label=TAGS,updateTime.date():label=UPDATED,metadata.imageSizeBytes.size(zero="0",precision=3,units_out=M):label=SIZE_MB)')"
}

# Lista los paquetes de un repositorio.
artifacts::packages() {
  artifacts::_parse "$@"
  ((${#_AR_POS[@]} == 1)) || core::usage_error "Indica un repositorio." "Uso: gcpctl artifacts packages <REPO>"
  core::validate_id REPO "${_AR_POS[0]}"
  core::ensure_project
  local location
  location="$(artifacts::_location)"
  core::gcloud artifacts packages list "--repository=${_AR_POS[0]}" "--location=${location}" "--limit=${_AR_LIMIT}" \
    "$(core::gcloud_format 'table(name.basename():label=PACKAGE,createTime.date(),updateTime.date())')"
}

# Lista las versiones de un paquete.
artifacts::versions() {
  artifacts::_parse "$@"
  ((${#_AR_POS[@]} == 2)) || core::usage_error "Indica repositorio y paquete." "Uso: gcpctl artifacts versions <REPO> <PAQUETE>"
  core::validate_id REPO "${_AR_POS[0]}"
  core::validate_id PAQUETE "${_AR_POS[1]}"
  core::ensure_project
  local location
  location="$(artifacts::_location)"
  core::gcloud artifacts versions list "--package=${_AR_POS[1]}" "--repository=${_AR_POS[0]}" \
    "--location=${location}" --sort-by=~updateTime "--limit=${_AR_LIMIT}" \
    "$(core::gcloud_format 'table(name.basename():label=VERSION,createTime.date(),updateTime.date(),relatedTags.list().basename():label=TAGS)')"
}
