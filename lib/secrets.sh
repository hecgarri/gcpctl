#!/usr/bin/env bash
# lib/secrets.sh — Secret Manager: metadatos de secretos y versiones.
#
# Por diseño NO existe ninguna acción que lea el valor de un secreto
# (gcloud secrets versions access): gcpctl sólo muestra metadatos.

registry::module secrets "Secret Manager: secretos y versiones (sin valores)" "secretmanager.googleapis.com"
registry::alias secret secrets
registry::action secrets list read "Lista los secretos (metadatos)"
registry::action secrets describe read "Metadatos de un secreto (replicación, rotación, etiquetas)" "<SECRETO>" "secret"
registry::action secrets versions read "Versiones de un secreto y su estado" "<SECRETO>" "secret"

# Lista los secretos.
secrets::list() {
  [[ $# -eq 0 ]] || core::usage_error "Argumento inesperado: $1"
  core::ensure_project
  core::gcloud secrets list \
    "$(core::gcloud_format 'table(name.basename():label=SECRET,createTime.date():label=CREATED,replication.userManaged.yesno(yes="gestionada",no="automática"):label=REPLICATION,rotation.nextRotationTime.date():label=NEXT_ROTATION,labels.list():label=LABELS)')"
}

# Metadatos de un secreto.
secrets::describe() {
  [[ $# -eq 1 ]] || core::usage_error "Indica un secreto." "Uso: gcpctl secrets describe <SECRETO>"
  core::validate_id SECRETO "$1"
  core::ensure_project
  core::gcloud secrets describe "$1" "$(core::gcloud_format yaml)"
}

# Versiones de un secreto.
secrets::versions() {
  [[ $# -eq 1 ]] || core::usage_error "Indica un secreto." "Uso: gcpctl secrets versions <SECRETO>"
  core::validate_id SECRETO "$1"
  core::ensure_project
  core::gcloud secrets versions list "$1" \
    "$(core::gcloud_format 'table(name.basename():label=VERSION,state,createTime.date():label=CREATED,destroyTime.date():label=DESTROYED)')"
}
