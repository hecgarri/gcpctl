#!/usr/bin/env bash
# lib/scheduler.sh — Cloud Scheduler: trabajos programados.

registry::module scheduler "Cloud Scheduler: trabajos programados" "cloudscheduler.googleapis.com"
registry::alias cron scheduler
registry::action scheduler locations read "Ubicaciones disponibles de Cloud Scheduler"
registry::action scheduler list read "Lista los trabajos de una ubicación" "[--location REGIÓN]"
registry::action scheduler describe read "Detalle de un trabajo" "<JOB> [--location REGIÓN]" "scheduler_job"
registry::action scheduler run write "Fuerza la ejecución inmediata de un trabajo" "<JOB> [--location REGIÓN]" "scheduler_job"
registry::action scheduler pause write "Pausa un trabajo" "<JOB> [--location REGIÓN]" "scheduler_job"
registry::action scheduler resume write "Reanuda un trabajo pausado" "<JOB> [--location REGIÓN]" "scheduler_job"

# Ubicación de Scheduler: --location > compute/region. Ojo: no todas las regiones
# de Cloud Run admiten Scheduler ('gcpctl scheduler locations').
scheduler::_location() { core::resolve_location "Cloud Scheduler" compute/region; }

# Lista las ubicaciones disponibles.
scheduler::locations() {
  core::ensure_project
  core::gcloud scheduler locations list "$(core::gcloud_format 'table(locationId:label=LOCATION,displayName)')"
}

# Lista los trabajos.
scheduler::list() {
  [[ $# -eq 0 ]] || core::usage_error "Argumento inesperado: $1" "Uso: gcpctl scheduler list [--location REGIÓN]"
  core::ensure_project
  local location
  location="$(scheduler::_location)"
  core::gcloud scheduler jobs list "--location=${location}" \
    "$(core::gcloud_format 'table(name.basename():label=JOB,schedule,timeZone,state,lastAttemptTime.date():label=LAST_RUN,status.code.yesno(no="OK"):label=LAST_STATUS,httpTarget.uri.yesno(no=""):label=TARGET)')"
}

# Detalle de un trabajo.
scheduler::describe() {
  [[ $# -eq 1 ]] || core::usage_error "Indica un trabajo." "Uso: gcpctl scheduler describe <JOB>"
  core::validate_id JOB "$1"
  core::ensure_project
  local location
  location="$(scheduler::_location)"
  core::gcloud scheduler jobs describe "$1" "--location=${location}" "$(core::gcloud_format yaml)"
}

# Operación de escritura común (run/pause/resume).
scheduler::_write() {
  local verb="$1" label="$2" job="${3:-}"
  core::validate_id JOB "$job"
  core::ensure_project
  local location
  location="$(scheduler::_location)"
  registry::confirm_write "${label} el trabajo ${job} (ubicación ${location})"
  core::gcloud scheduler jobs "$verb" "$job" "--location=${location}"
}

scheduler::run() {
  [[ $# -eq 1 ]] || core::usage_error "Indica un trabajo." "Uso: gcpctl scheduler run <JOB>"
  scheduler::_write run "ejecutar ahora" "$1"
}

scheduler::pause() {
  [[ $# -eq 1 ]] || core::usage_error "Indica un trabajo." "Uso: gcpctl scheduler pause <JOB>"
  scheduler::_write pause "pausar" "$1"
}

scheduler::resume() {
  [[ $# -eq 1 ]] || core::usage_error "Indica un trabajo." "Uso: gcpctl scheduler resume <JOB>"
  scheduler::_write resume "reanudar" "$1"
}
