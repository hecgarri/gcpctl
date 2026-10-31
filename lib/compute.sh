#!/usr/bin/env bash
# lib/compute.sh — Compute Engine: instancias, estado, arranque/parada y SSH (IAP).

registry::module compute "Compute Engine: instancias y conexión SSH/IAP" "compute.googleapis.com"
registry::alias gce compute
registry::action compute list read "Lista las instancias (opcional --zone)" "[--zone ZONA] [--filter EXPR]"
registry::action compute status read "Estado y datos de una instancia" "<INSTANCIA> [--zone ZONA]" "instance"
registry::action compute start write "Arranca una instancia" "<INSTANCIA> [--zone ZONA]" "instance"
registry::action compute stop write "Detiene una instancia" "<INSTANCIA> [--zone ZONA]" "instance"
registry::action compute ssh interactive "Conecta por SSH (IAP automático si no hay IP externa)" "<INSTANCIA> [--zone ZONA] [--iap] [--command CMD]" "instance"

# Rango de IP de Identity-Aware Proxy para reenvío TCP.
readonly COMPUTE_IAP_RANGE="35.235.240.0/20"

# Resuelve la zona de una instancia: --zone > búsqueda por nombre > compute/zone.
compute::_zone() {
  local name="$1" zones count
  if [[ -n "$GCPCTL_ZONE" ]]; then
    printf '%s' "$GCPCTL_ZONE"
    return
  fi
  local GCPCTL_DRY_RUN=0
  zones="$(core::gcloud compute instances list "--filter=name=(${name})" --format='value(zone.basename())')" || return
  count="$(grep -c . <<<"$zones" || true)"
  if ((count == 1)); then
    printf '%s' "$zones"
    return
  elif ((count > 1)); then
    core::usage_error "Hay varias instancias '${name}' (zonas: ${zones//$'\n'/, })." "Indica la zona con --zone."
  fi
  zones="$(core::gcloud_prop compute/zone)"
  [[ -n "$zones" ]] || core::die "No se encontró la instancia '${name}' en el proyecto ${CORE_PROJECT}."
  printf '%s' "$zones"
}

# Lista instancias.
compute::list() {
  local args=(compute instances list)
  while (($#)); do
    case "$1" in
      --filter)
        core::need_value "$1" "${2:-}"
        args+=("--filter=$2")
        shift 2
        ;;
      *) core::usage_error "Opción desconocida: $1" "Uso: gcpctl compute list [--zone ZONA] [--filter EXPR]" ;;
    esac
  done
  [[ -n "$GCPCTL_ZONE" ]] && args+=("--zones=${GCPCTL_ZONE}")
  core::ensure_project
  core::gcloud "${args[@]}" \
    "$(core::gcloud_format 'table(name,zone.basename():label=ZONE,machineType.basename():label=MACHINE_TYPE,status,networkInterfaces[0].networkIP:label=INTERNAL_IP,networkInterfaces[0].accessConfigs[0].natIP:label=EXTERNAL_IP)')"
}

# Muestra el estado y los datos principales de una instancia.
compute::status() {
  [[ $# -eq 1 ]] || core::usage_error "Indica una instancia." "Uso: gcpctl compute status <INSTANCIA>"
  core::validate_id INSTANCIA "$1"
  core::ensure_project
  local zone
  zone="$(compute::_zone "$1")"
  if core::is_table; then
    core::gcloud compute instances describe "$1" "--zone=${zone}" \
      --format='yaml(name,status,zone.basename(),machineType.basename(),creationTimestamp,lastStartTimestamp,lastStopTimestamp,networkInterfaces[].networkIP,networkInterfaces[].accessConfigs[].natIP,serviceAccounts[].email,labels,scheduling.preemptible)'
  else
    core::gcloud compute instances describe "$1" "--zone=${zone}" "$(core::gcloud_format)"
  fi
}

# Operación común de arranque/parada con confirmación.
compute::_power() {
  local verb="$1" name="${2:-}"
  core::validate_id INSTANCIA "$name"
  core::ensure_project
  local zone
  zone="$(compute::_zone "$name")"
  registry::confirm_write "${verb} de la instancia ${name} (zona ${zone})"
  core::gcloud compute instances "$verb" "$name" "--zone=${zone}"
  [[ "$GCPCTL_DRY_RUN" == 1 ]] || core::ok "Instancia ${name}: ${verb} solicitado."
}

# Arranca una instancia.
compute::start() {
  [[ $# -eq 1 ]] || core::usage_error "Indica una instancia." "Uso: gcpctl compute start <INSTANCIA>"
  compute::_power start "$1"
}

# Detiene una instancia.
compute::stop() {
  [[ $# -eq 1 ]] || core::usage_error "Indica una instancia." "Uso: gcpctl compute stop <INSTANCIA>"
  compute::_power stop "$1"
}

# Avisa si no existe ninguna regla de firewall que permita el rango de IAP.
compute::_check_iap_firewall() {
  # shellcheck disable=SC2034  # Sobrescriben los globales para esta lectura.
  local GCPCTL_DRY_RUN=0 GCPCTL_QUIET=1 rules
  rules="$(core::gcloud compute firewall-rules list \
    "--filter=sourceRanges:${COMPUTE_IAP_RANGE} AND direction=INGRESS AND disabled=false" \
    --format='value(name)' 2>/dev/null)" || {
    core::warn "No se pudieron comprobar las reglas de firewall para IAP."
    return 0
  }
  if [[ -z "$rules" ]]; then
    core::warn "No hay reglas de firewall que permitan ${COMPUTE_IAP_RANGE} (IAP). La conexión puede fallar."
    printf '  Ejemplo: gcloud compute firewall-rules create allow-iap-ssh --network=<RED> --allow=tcp:22 --source-ranges=%s\n' "$COMPUTE_IAP_RANGE" >&2
  else
    core::debug "Reglas IAP: ${rules//$'\n'/, }"
  fi
}

# Conecta por SSH. Usa IAP si se pide (--iap) o si la instancia no tiene IP externa.
compute::ssh() {
  local name="" iap=0 cmd=() extra=()
  while (($#)); do
    case "$1" in
      --iap)
        iap=1
        shift
        ;;
      --command)
        core::need_value "$1" "${2:-}"
        cmd=("--command=$2")
        shift 2
        ;;
      --)
        shift
        extra=(-- "$@")
        break
        ;;
      -*) core::usage_error "Opción desconocida: $1" ;;
      *)
        [[ -z "$name" ]] || core::usage_error "Argumento inesperado: $1"
        name="$1"
        shift
        ;;
    esac
  done
  core::validate_id INSTANCIA "$name"
  core::ensure_project
  local zone nat
  zone="$(compute::_zone "$name")"
  if ((iap == 0)) && [[ "$GCPCTL_DRY_RUN" != 1 ]]; then
    nat="$(core::gcloud compute instances describe "$name" "--zone=${zone}" \
      --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || true)"
    if [[ -z "$nat" ]]; then
      core::info "La instancia no tiene IP externa: se usará IAP (--tunnel-through-iap)."
      iap=1
    fi
  fi
  local args=(compute ssh "$name" "--zone=${zone}" "${cmd[@]}")
  if ((iap == 1)); then
    args+=(--tunnel-through-iap)
    [[ "$GCPCTL_DRY_RUN" == 1 ]] || compute::_check_iap_firewall
  fi
  core::gcloud_interactive "${args[@]}" "${extra[@]}"
}
