#!/usr/bin/env bash
# ui/picker.sh — Primitivas de interacción independientes del backend:
# selección (fzf o lista numerada con filtro), entrada de texto y confirmación
# (gum si está disponible, si no 'read'). No contiene lógica de GCP.
#
# Convención: las selecciones se imprimen en stdout; los menús y mensajes, en
# stderr o en la terminal. Código 130 = el usuario canceló / quiere volver.

[[ -n "${_GCPCTL_PICKER_LOADED:-}" ]] && return 0
_GCPCTL_PICKER_LOADED=1

# Backend de selección: fzf si está disponible, si no 'basic'.
# Puede forzarse con GCPCTL_PICKER=fzf|basic.
picker::backend() {
  case "${GCPCTL_PICKER:-auto}" in
    fzf | basic) printf '%s' "$GCPCTL_PICKER" ;;
    *) if core::has_cmd fzf; then printf 'fzf'; else printf 'basic'; fi ;;
  esac
}

# Devuelve 0 si gum puede usarse para entradas/confirmaciones.
picker::_use_gum() {
  [[ "${GCPCTL_PICKER:-auto}" != basic ]] && core::has_cmd gum && [[ -t 0 ]]
}

# Muestra una lista y devuelve el valor elegido.
# Cada elemento es "valor<TAB>etiqueta" (o sólo "valor").
# Uso: picker::choose <prompt> <cabecera> <elemento>...
picker::choose() {
  local prompt="$1" header="$2"
  shift 2
  (($# > 0)) || {
    core::warn "No hay elementos para seleccionar."
    return 1
  }
  local items=() it
  for it in "$@"; do
    [[ "$it" == *$'\t'* ]] || it="${it}"$'\t'"${it}"
    items+=("$it")
  done
  if [[ "$(picker::backend)" == fzf ]]; then
    picker::_choose_fzf "$prompt" "$header" "${items[@]}"
  else
    picker::_choose_basic "$prompt" "$header" "${items[@]}"
  fi
}

# Selección con fzf: búsqueda incremental, Esc para volver.
picker::_choose_fzf() {
  local prompt="$1" header="$2" sel rc=0
  shift 2
  sel="$(printf '%s\n' "$@" | fzf --delimiter=$'\t' --with-nth=2.. \
    --prompt="${prompt} › " --header="${header}"$'\n'"Enter: elegir · Esc: volver · escribe para filtrar" \
    --height=~90% --layout=reverse --border=rounded --info=inline --cycle --no-multi --ansi)" || rc=$?
  if ((rc != 0)); then
    return "$EX_CANCELLED"
  fi
  printf '%s' "${sel%%$'\t'*}"
}

# Selección básica: lista numerada; texto = filtro, 0/q/Enter vacío = volver.
picker::_choose_basic() {
  local prompt="$1" header="$2" filter="" answer i n
  shift 2
  local all=("$@") shown=()
  while true; do
    shown=()
    for i in "${all[@]}"; do
      if [[ -z "$filter" || "${i,,}" == *"${filter,,}"* ]]; then shown+=("$i"); fi
    done
    {
      printf '\n%s\n' "$header"
      [[ -n "$filter" ]] && printf '(filtro: "%s")\n' "$filter"
      n=0
      for i in "${shown[@]}"; do
        n=$((n + 1))
        printf '  %3d) %s\n' "$n" "${i#*$'\t'}"
      done
      ((n == 0)) && printf '  (sin coincidencias)\n'
      printf '    0) ← Volver\n%s [número, texto para filtrar, /: quitar filtro]: ' "$prompt"
    } >&2
    IFS= read -r answer || return "$EX_CANCELLED"
    case "$answer" in
      0 | q | Q) return "$EX_CANCELLED" ;;
      "")
        [[ -z "$filter" ]] && return "$EX_CANCELLED"
        filter=""
        ;;
      /) filter="" ;;
      *[!0-9]*) filter="$answer" ;;
      *)
        if ((answer >= 1 && answer <= ${#shown[@]})); then
          i="${shown[answer - 1]}"
          printf '%s' "${i%%$'\t'*}"
          return 0
        fi
        printf 'Opción fuera de rango.\n' >&2
        ;;
    esac
  done
}

# Pide un texto. Uso: valor="$(picker::input <prompt> [valor_por_defecto])"
picker::input() {
  local prompt="$1" default="${2:-}" value=""
  if picker::_use_gum; then
    value="$(gum input --prompt="${prompt}: " --value="$default")" || return "$EX_CANCELLED"
  else
    printf '%s%s: ' "$prompt" "${default:+ [$default]}" >&2
    IFS= read -r value || return "$EX_CANCELLED"
    [[ -z "$value" ]] && value="$default"
  fi
  [[ -n "$value" ]] || return "$EX_CANCELLED"
  printf '%s' "$value"
}

# Pregunta sí/no (por defecto no). Uso: picker::confirm "¿Seguro?"
picker::confirm() {
  local answer=""
  if picker::_use_gum; then
    gum confirm --default=false "$1"
    return
  fi
  printf '%s [s/N]: ' "$1" >&2
  IFS= read -r answer || return 1
  [[ "${answer,,}" =~ ^(s|si|sí|y|yes)$ ]]
}

# Espera a que el usuario pulse Enter.
picker::pause() {
  local _
  printf '\n%sPulsa Enter para continuar…%s' "$C_DIM" "$C_RESET" >&2
  IFS= read -r _ || true
}
