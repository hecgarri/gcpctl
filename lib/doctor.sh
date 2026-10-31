#!/usr/bin/env bash
# lib/doctor.sh — Diagnóstico del entorno: dependencias, autenticación,
# proyecto y APIs requeridas por cada módulo.

registry::module doctor "Diagnóstico de dependencias, autenticación y APIs"
registry::action doctor check read "Comprueba dependencias, cuenta, proyecto y APIs habilitadas"
registry::default doctor check

# Imprime una línea de diagnóstico con estado OK / AVISO / FALLO.
doctor::_line() {
  local status="$1" label="$2" detail="${3:-}" color
  case "$status" in
    OK) color="$C_GREEN" ;;
    AVISO) color="$C_YELLOW" ;;
    *) color="$C_RED" ;;
  esac
  printf '  %s%-6s%s %-28s %s\n' "$color" "$status" "$C_RESET" "$label" "$detail"
}

# Ejecuta el diagnóstico completo. Devuelve 1 si falta algo imprescindible.
doctor::check() {
  local failed=0 cmd account project enabled module api
  printf '%sDependencias%s\n' "$C_BOLD" "$C_RESET"
  for cmd in gcloud jq; do
    if core::has_cmd "$cmd"; then doctor::_line OK "$cmd" "$(command -v "$cmd")"; else
      doctor::_line FALLO "$cmd" "obligatorio"
      failed=1
    fi
  done
  for cmd in bq fzf gum; do
    if core::has_cmd "$cmd"; then doctor::_line OK "$cmd" "$(command -v "$cmd")"; else doctor::_line AVISO "$cmd" "opcional, no instalado"; fi
  done
  ((failed)) && return "$EX_DEPENDENCY"
  doctor::_line OK "gcloud SDK" "$(gcloud version 2>/dev/null | head -n1)"
  doctor::_line OK "bash" "$BASH_VERSION"

  printf '\n%sAutenticación y contexto%s\n' "$C_BOLD" "$C_RESET"
  account="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n1 || true)"
  if [[ -n "$account" ]]; then doctor::_line OK "cuenta activa" "$account"; else
    doctor::_line FALLO "cuenta activa" "ninguna (gcloud auth login)"
    failed=1
  fi
  project="${GCPCTL_PROJECT:-${CLOUDSDK_CORE_PROJECT:-$(core::gcloud_prop project)}}"
  if [[ -n "$project" ]]; then
    doctor::_line OK "proyecto" "$project$(core::is_prod "$project" && printf ' (PRODUCCIÓN)')"
  else
    doctor::_line FALLO "proyecto" "sin definir (--project o gcpctl projects use)"
    return 1
  fi
  local p
  for p in compute/region compute/zone; do
    local v
    v="$(core::gcloud_prop "$p")"
    if [[ -n "$v" ]]; then doctor::_line OK "$p" "$v"; else doctor::_line AVISO "$p" "sin definir"; fi
  done
  ((failed)) && return 1

  printf '\n%sAPIs habilitadas en %s%s\n' "$C_BOLD" "$project" "$C_RESET"
  if ! enabled="$(gcloud services list --enabled --project="$project" --format='value(config.name)' 2>/dev/null)"; then
    doctor::_line AVISO "serviceusage" "no se pudo consultar (permiso serviceusage.services.list)"
    return 0
  fi
  for module in "${REG_MODULES[@]}"; do
    for api in ${REG_MODULE_APIS[$module]}; do
      if grep -qx "$api" <<<"$enabled"; then
        doctor::_line OK "$module" "$api"
      else
        doctor::_line AVISO "$module" "$api deshabilitada → gcloud services enable $api --project $project"
      fi
    done
  done
  return 0
}
