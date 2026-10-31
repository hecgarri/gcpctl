#!/usr/bin/env bash
# install.sh — Instala gcpctl en un directorio propio y crea un enlace
# simbólico accesible desde el PATH.
#
# Por defecto (usuario, sin sudo):
#   ~/.local/share/gcpctl  +  ~/.local/bin/gcpctl
# Con --system:
#   /opt/gcpctl            +  /usr/local/bin/gcpctl   (requiere permisos)

set -euo pipefail

SRC_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
PREFIX="${XDG_DATA_HOME:-$HOME/.local/share}/gcpctl"
BIN_DIR="$HOME/.local/bin"
FORCE=0
COMPLETION=1
readonly MARKER=".gcpctl-install"
readonly PAYLOAD=(bin lib ui VERSION README.md LICENSE uninstall.sh)

usage() {
  cat <<EOF
Uso: ./install.sh [opciones]

Opciones:
  --prefix DIR     Directorio de instalación (por defecto: ${PREFIX})
  --bin-dir DIR    Directorio del enlace simbólico (por defecto: ${BIN_DIR})
  --system         Instalación global: /opt/gcpctl y /usr/local/bin
  --no-completion  No instalar el autocompletado de Bash
  --force          Sobrescribe una instalación o un archivo existente
  -h, --help       Muestra esta ayuda
EOF
}

die() {
  printf 'Error: %s\n' "$1" >&2
  exit "${2:-1}"
}
info() { printf '→ %s\n' "$*"; }

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
    --no-completion)
      COMPLETION=0
      shift
      ;;
    --force)
      FORCE=1
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

# Comprueba dependencias (avisa de las opcionales).
check_deps() {
  local missing=0 cmd
  ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4))) ||
    die "Se requiere Bash >= 4.4 (actual: ${BASH_VERSION})"
  for cmd in gcloud jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      printf 'Aviso: falta la dependencia obligatoria %s\n' "$cmd" >&2
      missing=1
    fi
  done
  for cmd in bq fzf gum; do
    command -v "$cmd" >/dev/null 2>&1 || printf 'Nota: %s (opcional) no está instalado.\n' "$cmd"
  done
  ((missing == 0)) || printf 'gcpctl se instalará, pero no funcionará hasta instalar las dependencias obligatorias.\n' >&2
}

# Copia los archivos de la aplicación al directorio de instalación.
install_payload() {
  local item
  [[ "$(readlink -f -- "$PREFIX" 2>/dev/null || true)" != "$SRC_DIR" ]] ||
    die "El directorio de instalación no puede ser el propio repositorio."
  if [[ -e "$PREFIX" && ! -f "$PREFIX/$MARKER" ]]; then
    ((FORCE)) || die "${PREFIX} existe y no es una instalación de gcpctl (usa --force si es correcto)."
  fi
  mkdir -p "$PREFIX"
  for item in bin lib ui; do rm -rf "${PREFIX:?}/$item"; done
  for item in "${PAYLOAD[@]}"; do
    [[ -e "$SRC_DIR/$item" ]] && cp -R "$SRC_DIR/$item" "$PREFIX/"
  done
  chmod 0755 "$PREFIX/bin/gcpctl"
  printf 'version=%s\ninstalled=%s\nbin=%s\n' "$(cat "$SRC_DIR/VERSION")" "$(date -u +%FT%TZ)" "$BIN_DIR/gcpctl" >"$PREFIX/$MARKER"
}

# Crea (o actualiza) el enlace simbólico en BIN_DIR.
install_link() {
  local link="$BIN_DIR/gcpctl"
  mkdir -p "$BIN_DIR"
  if [[ -e "$link" || -L "$link" ]]; then
    if [[ -L "$link" && "$(readlink -f -- "$link")" == "$(readlink -f -- "$PREFIX/bin/gcpctl")" ]]; then
      :
    elif [[ -L "$link" && "$(readlink -- "$link")" == */gcpctl/bin/gcpctl ]] || ((FORCE)); then
      rm -f "$link"
    else
      die "${link} ya existe y no apunta a gcpctl (usa --force para reemplazarlo)."
    fi
  fi
  ln -sfn "$PREFIX/bin/gcpctl" "$link"
}

# Instala el autocompletado de Bash para el usuario (no requiere root).
install_completion() {
  ((COMPLETION)) || return 0
  local dir="${BASH_COMPLETION_USER_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion}/completions"
  [[ "$PREFIX" == /opt/* ]] && [[ -w /etc/bash_completion.d ]] && dir=/etc/bash_completion.d
  if mkdir -p "$dir" 2>/dev/null && "$PREFIX/bin/gcpctl" completion bash >"$dir/gcpctl" 2>/dev/null; then
    info "Autocompletado instalado en $dir/gcpctl"
  else
    printf 'Aviso: no se pudo instalar el autocompletado (usa: source <(gcpctl completion bash)).\n' >&2
  fi
}

check_deps
info "Instalando gcpctl $(cat "$SRC_DIR/VERSION") en ${PREFIX}"
install_payload
install_link
install_completion
info "Enlace: ${BIN_DIR}/gcpctl → ${PREFIX}/bin/gcpctl"

case ":${PATH}:" in
  *":${BIN_DIR}:"*) ;;
  *) printf '\nAviso: %s no está en tu PATH. Añade a ~/.bashrc:\n  export PATH="%s:%s"\n' "$BIN_DIR" "$BIN_DIR" "\$PATH" ;;
esac
printf '\n✔ Instalación completada. Prueba: gcpctl --version && gcpctl doctor\n'
