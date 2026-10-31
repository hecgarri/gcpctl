#!/usr/bin/env bash
# lib/pubsub.sh — Pub/Sub: temas y suscripciones (sólo lectura).

registry::module pubsub "Pub/Sub: temas y suscripciones" "pubsub.googleapis.com"
registry::alias ps pubsub
registry::action pubsub topics read "Lista los temas"
registry::action pubsub subscriptions read "Lista las suscripciones (opcional: de un tema)" "[TEMA]" "pubsub_topic?"
registry::action pubsub subscription read "Detalle de una suscripción" "<SUSCRIPCIÓN>" "pubsub_subscription"

# Lista los temas.
pubsub::topics() {
  [[ $# -eq 0 ]] || core::usage_error "Argumento inesperado: $1"
  core::ensure_project
  core::gcloud pubsub topics list \
    "$(core::gcloud_format 'table(name.basename():label=TOPIC,messageRetentionDuration:label=RETENTION,labels.list():label=LABELS)')"
}

# Lista las suscripciones, todas o las de un tema.
pubsub::subscriptions() {
  [[ $# -le 1 ]] || core::usage_error "Demasiados argumentos." "Uso: gcpctl pubsub subscriptions [TEMA]"
  core::ensure_project
  local projection='table(name.basename():label=SUBSCRIPTION,topic.basename():label=TOPIC,pushConfig.pushEndpoint.yesno(no="pull"):label=DELIVERY,ackDeadlineSeconds:label=ACK_S,messageRetentionDuration:label=RETENTION,state)'
  if [[ $# -eq 1 ]]; then
    core::validate_id TEMA "$1"
    core::gcloud pubsub subscriptions list "--filter=topic:$(core::filter_quote "projects/${CORE_PROJECT}/topics/${1##*/}")" \
      "$(core::gcloud_format "$projection")"
  else
    core::gcloud pubsub subscriptions list "$(core::gcloud_format "$projection")"
  fi
}

# Detalle de una suscripción.
pubsub::subscription() {
  [[ $# -eq 1 ]] || core::usage_error "Indica una suscripción." "Uso: gcpctl pubsub subscription <SUSCRIPCIÓN>"
  core::validate_id SUSCRIPCIÓN "$1"
  core::ensure_project
  core::gcloud pubsub subscriptions describe "$1" "$(core::gcloud_format yaml)"
}
