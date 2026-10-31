# Utilidades comunes para las pruebas bats de gcpctl.

# Prepara un entorno aislado: stubs en el PATH y configuración de gcloud temporal.
gcpctl_setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export GCPCTL="${REPO_ROOT}/bin/gcpctl"
  export PATH="${REPO_ROOT}/tests/stubs:${PATH}"
  export STUB_LOG="${BATS_TEST_TMPDIR}/calls.log"
  export CLOUDSDK_CONFIG="${BATS_TEST_TMPDIR}/gcloud-config"
  export STUB_PROP_project="test-project"
  export GCPCTL_NO_COLOR=1 NO_COLOR=1 GCPCTL_NO_TTY=1
  unset GCPCTL_PROJECT GCPCTL_FORMAT GCPCTL_REGION GCPCTL_ZONE GCPCTL_LOCATION \
    GCPCTL_YES GCPCTL_DRY_RUN CLOUDSDK_CORE_PROJECT GCPCTL_FORCE_PROD GCPCTL_HOME
  : >"$STUB_LOG"
}

# Comprueba que alguna invocación registrada contenga el texto dado.
assert_called() {
  if ! grep -qF -- "$1" "$STUB_LOG"; then
    printf 'No se encontró la invocación: %s\nRegistro:\n%s\n' "$1" "$(cat "$STUB_LOG")" >&2
    return 1
  fi
}

# Comprueba que ninguna invocación contenga el texto dado.
refute_called() {
  if grep -qF -- "$1" "$STUB_LOG"; then
    printf 'Invocación inesperada: %s\nRegistro:\n%s\n' "$1" "$(cat "$STUB_LOG")" >&2
    return 1
  fi
}
