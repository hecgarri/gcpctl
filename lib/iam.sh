#!/usr/bin/env bash
# lib/iam.sh — IAM: políticas del proyecto y cuentas de servicio (sólo lectura).

registry::module iam "IAM: políticas y cuentas de servicio" "iam.googleapis.com cloudresourcemanager.googleapis.com"
registry::action iam policy read "Política IAM del proyecto (rol/miembro)" "[--member MIEMBRO] [--role ROL]"
registry::action iam sa read "Lista las cuentas de servicio"
registry::action iam sa-keys read "Claves de una cuenta de servicio" "<EMAIL_SA>" "service_account"
registry::action iam sa-policy read "Quién puede usar/administrar una cuenta de servicio" "<EMAIL_SA>" "service_account"

# Muestra la política IAM del proyecto, opcionalmente filtrada por miembro o rol.
iam::policy() {
  local filters=()
  while (($#)); do
    case "$1" in
      --member)
        core::need_value "$1" "${2:-}"
        filters+=("bindings.members:$(core::filter_quote "$2")")
        shift 2
        ;;
      --role)
        core::need_value "$1" "${2:-}"
        filters+=("bindings.role=$(core::filter_quote "$2")")
        shift 2
        ;;
      *) core::usage_error "Opción desconocida: $1" "Uso: gcpctl iam policy [--member MIEMBRO] [--role ROL]" ;;
    esac
  done
  core::ensure_project
  local args=(projects get-iam-policy "$CORE_PROJECT")
  if ((${#filters[@]})) || core::is_table || [[ "$GCPCTL_FORMAT" == csv ]]; then
    args+=("--flatten=bindings[].members")
  fi
  if ((${#filters[@]})); then
    local f joined=""
    for f in "${filters[@]}"; do joined+="${joined:+ AND }${f}"; done
    args+=("--filter=${joined}")
  fi
  core::gcloud "${args[@]}" "$(core::gcloud_format 'table(bindings.role:sort=1,bindings.members:label=MEMBER,bindings.condition.title:label=CONDITION)')"
}

# Lista las cuentas de servicio del proyecto.
iam::sa() {
  [[ $# -eq 0 ]] || core::usage_error "Argumento inesperado: $1"
  core::ensure_project
  core::gcloud iam service-accounts list "$(core::gcloud_format 'table(email,displayName,disabled)')"
}

# Lista las claves de una cuenta de servicio.
iam::sa_keys() {
  [[ $# -eq 1 ]] || core::usage_error "Indica la cuenta de servicio." "Uso: gcpctl iam sa-keys <EMAIL_SA>"
  core::validate_id EMAIL_SA "$1"
  core::ensure_project
  core::gcloud iam service-accounts keys list "--iam-account=$1" \
    "$(core::gcloud_format 'table(name.basename():label=KEY_ID,keyType,validAfterTime,validBeforeTime,disabled)')"
}

# Muestra la política IAM de una cuenta de servicio.
iam::sa_policy() {
  [[ $# -eq 1 ]] || core::usage_error "Indica la cuenta de servicio." "Uso: gcpctl iam sa-policy <EMAIL_SA>"
  core::validate_id EMAIL_SA "$1"
  core::ensure_project
  local args=(iam service-accounts get-iam-policy "$1")
  core::is_table && args+=("--flatten=bindings[].members")
  core::gcloud "${args[@]}" "$(core::gcloud_format 'table(bindings.role,bindings.members:label=MEMBER)')"
}
