#!/usr/bin/env bash
# lib/composer.sh — Cloud Composer: entornos y DAGs.

registry::module composer "Cloud Composer: entornos y DAGs" "composer.googleapis.com"
registry::alias airflow composer
registry::action composer list read "Lista los entornos de una ubicación" "[--location REGIÓN]"
registry::action composer describe read "Muestra la información de un entorno" "<ENTORNO> [--location REGIÓN]" "composer_env"
registry::action composer dags read "Lista los DAGs de un entorno (airflow dags list)" "<ENTORNO> [--location REGIÓN]" "composer_env"

# Ubicación de Composer: --location > composer/location > compute/region.
composer::_location() {
  core::resolve_location "Cloud Composer" composer/location compute/region
}

# Lista los entornos de Composer.
composer::list() {
  [[ $# -eq 0 ]] || core::usage_error "Argumento inesperado: $1" "Uso: gcpctl composer list [--location REGIÓN]"
  core::ensure_project
  local location
  location="$(composer::_location)"
  core::gcloud composer environments list "--locations=${location}" \
    "$(core::gcloud_format 'table(name.basename():label=NAME,name.segment(3):label=LOCATION,state,config.softwareConfig.imageVersion:label=IMAGE,config.airflowUri:label=AIRFLOW_UI)')"
}

# Muestra la información de un entorno.
composer::describe() {
  [[ $# -eq 1 ]] || core::usage_error "Indica un entorno." "Uso: gcpctl composer describe <ENTORNO>"
  core::validate_id ENTORNO "$1"
  core::ensure_project
  local location
  location="$(composer::_location)"
  if core::wants_summary; then
    core::gcloud composer environments describe "$1" "--location=${location}" \
      --format='yaml(name,state,createTime,updateTime,config.softwareConfig.imageVersion,config.environmentSize,config.airflowUri,config.dagGcsPrefix,config.nodeConfig.serviceAccount,config.privateEnvironmentConfig.enablePrivateEnvironment,labels)'
  else
    core::gcloud composer environments describe "$1" "--location=${location}" "$(core::gcloud_format)"
  fi
}

# Lista los DAGs ejecutando 'airflow dags list' dentro del entorno.
composer::dags() {
  [[ $# -eq 1 ]] || core::usage_error "Indica un entorno." "Uso: gcpctl composer dags <ENTORNO>"
  core::validate_id ENTORNO "$1"
  core::ensure_project
  local location output
  location="$(composer::_location)"
  case "$GCPCTL_FORMAT" in
    json) output=json ;;
    yaml) output=yaml ;;
    csv) output=plain ;;
    *) output=table ;;
  esac
  core::gcloud composer environments run "$1" "--location=${location}" dags list -- -o "$output"
}
