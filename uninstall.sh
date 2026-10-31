#!/usr/bin/env bash
# uninstall.sh — Desinstala gcpctl. Elimina sólo el directorio de instalación
# (si contiene el marcador de gcpctl), el enlace simbólico y el autocompletado.
# NUNCA toca la configuración de gcloud (~/.config/gcloud) ni recursos de GCP.

set -euo pipefail

PREFIX="${XDG_DATA_HOME:-$HOME/.local/share}/gcpctl"
BIN_DIR="$HOME/.local/bin"
YES=0
readonly MARKER=".gcpctl-install"

usage() {
  cat <<EOF
Uso: ./uninstall.sh [opciones]

Opciones:
  --prefix DIR    Directorio de instalación (por defecto: ${PREFIX})
  --bin-dir DIR   Directorio del enlace simbólico (por defecto: ${BIN_DIR})
  --system        Desinstala la instalación global (/opt/gcpctl, /usr/local/bin)
  -y, --yes       No pedir confirmación
  -h, --help      Muestra esta ayuda

No se elimina ninguna configuración ni credencial de Google Cloud CLI.
EOF
}

die() {
  printf 'Error: %s\n' "$1" >&2
  exit "${2:-1}"
}

while (($#)); do
  case "$1" in
    --prefix)
      [[ -n "${2:-}" ]] || die "--prefix requiere un valor" 2
      PREFIX="$2"
      shift 2
      ;;
    --bin-dir)
      [[ -n "${2:-}" ]] || die "--bin-dir requiere un valor" 2
      BIN_DIR="$2"
      shift 2
      ;;
    --system)
      PREFIX=/opt/gcpctl
      BIN_DIR=/usr/local/bin
      shift
      ;;
    -y | --yes)
      YES=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "Opción desconocida: $1 (usa --help)" 2 ;;
  esac
done

# Rutas absolutas normalizadas (el enlace debe apuntar a una ruta absoluta).
PREFIX="$(realpath -m -- "$PREFIX")"
BIN_DIR="$(realpath -m -- "$BIN_DIR")"

[[ -f "$PREFIX/$MARKER" ]] || die "No se encontró una instalación de gcpctl en ${PREFIX} (falta ${MARKER})."

if ((YES == 0)); then
  printf 'Se eliminarán:\n  %s\n  %s/gcpctl (enlace)\n¿Continuar? [s/N]: ' "$PREFIX" "$BIN_DIR"
  read -r answer || answer=""
  [[ "${answer,,}" =~ ^(s|si|sí|y|yes)$ ]] || die "Cancelado." 130
fi

link="$BIN_DIR/gcpctl"
if [[ -L "$link" && "$(readlink -- "$link")" == "$PREFIX/bin/gcpctl" ]]; then
  rm -f "$link"
  printf '→ Enlace eliminado: %s\n' "$link"
elif [[ -e "$link" ]]; then
  printf 'Aviso: %s no apunta a esta instalación; no se elimina.\n' "$link" >&2
fi

for comp in "${BASH_COMPLETION_USER_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion}/completions/gcpctl" /etc/bash_completion.d/gcpctl; do
  if [[ -f "$comp" && -w "$comp" ]] && grep -q '_gcpctl' "$comp"; then
    rm -f "$comp"
    printf '→ Autocompletado eliminado: %s\n' "$comp"
  fi
done

rm -rf -- "${PREFIX:?}"
printf '→ Directorio eliminado: %s\n' "$PREFIX"
printf '\n✔ gcpctl desinstalado. La configuración de gcloud no se ha modificado.\n'
