#!/usr/bin/env bats
# Pruebas de install.sh / uninstall.sh en directorios temporales.

load helpers/common

setup() {
  gcpctl_setup
  export HOME="${BATS_TEST_TMPDIR}/home"
  export XDG_DATA_HOME="${HOME}/.local/share"
  mkdir -p "$HOME"
  PREFIX="${BATS_TEST_TMPDIR}/inst/gcpctl"
  BIN="${BATS_TEST_TMPDIR}/bin"
}

@test "install.sh instala, enlaza y el binario funciona" {
  run "${REPO_ROOT}/install.sh" --prefix "$PREFIX" --bin-dir "$BIN"
  [ "$status" -eq 0 ]
  [ -L "${BIN}/gcpctl" ]
  [ -f "${PREFIX}/.gcpctl-install" ]
  [ ! -d "${PREFIX}/tests" ]
  run "${BIN}/gcpctl" --version
  [ "$status" -eq 0 ]
  [[ "$output" == gcpctl* ]]
  [ -f "${XDG_DATA_HOME}/bash-completion/completions/gcpctl" ]
}

@test "install.sh es idempotente" {
  "${REPO_ROOT}/install.sh" --prefix "$PREFIX" --bin-dir "$BIN" >/dev/null
  run "${REPO_ROOT}/install.sh" --prefix "$PREFIX" --bin-dir "$BIN"
  [ "$status" -eq 0 ]
}

@test "install.sh no sobrescribe un directorio ajeno sin --force" {
  mkdir -p "$PREFIX"
  touch "${PREFIX}/importante"
  run "${REPO_ROOT}/install.sh" --prefix "$PREFIX" --bin-dir "$BIN"
  [ "$status" -ne 0 ]
  [ -f "${PREFIX}/importante" ]
}

@test "install.sh no reemplaza un ejecutable ajeno sin --force" {
  mkdir -p "$BIN"
  printf '#!/bin/sh\n' >"${BIN}/gcpctl"
  run "${REPO_ROOT}/install.sh" --prefix "$PREFIX" --bin-dir "$BIN"
  [ "$status" -ne 0 ]
  [ ! -L "${BIN}/gcpctl" ]
}

@test "uninstall.sh elimina la instalación pero no la configuración de gcloud" {
  mkdir -p "$CLOUDSDK_CONFIG"
  touch "${CLOUDSDK_CONFIG}/active_config"
  "${REPO_ROOT}/install.sh" --prefix "$PREFIX" --bin-dir "$BIN" >/dev/null
  run "${REPO_ROOT}/uninstall.sh" --prefix "$PREFIX" --bin-dir "$BIN" --yes
  [ "$status" -eq 0 ]
  [ ! -e "${BIN}/gcpctl" ]
  [ ! -d "$PREFIX" ]
  [ -f "${CLOUDSDK_CONFIG}/active_config" ]
}

@test "uninstall.sh se niega si no hay marcador de instalación" {
  mkdir -p "$PREFIX"
  run "${REPO_ROOT}/uninstall.sh" --prefix "$PREFIX" --bin-dir "$BIN" --yes
  [ "$status" -ne 0 ]
  [ -d "$PREFIX" ]
}
