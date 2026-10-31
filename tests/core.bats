#!/usr/bin/env bats
# Pruebas unitarias de lib/core.sh.

load helpers/common

setup() {
  gcpctl_setup
  source "${REPO_ROOT}/lib/core.sh"
}

@test "core::gcloud_format mapea table/json/yaml/csv" {
  GCPCTL_FORMAT=table
  [ "$(core::gcloud_format 'table(a,b)')" = "--format=table(a,b)" ]
  GCPCTL_FORMAT=json
  [ "$(core::gcloud_format 'table(a,b)')" = "--format=json" ]
  GCPCTL_FORMAT=yaml
  [ "$(core::gcloud_format)" = "--format=yaml" ]
  GCPCTL_FORMAT=csv
  [ "$(core::gcloud_format 'table(a,b)')" = "--format=csv(a,b)" ]
}

@test "core::bq_format mapea los formatos de bq" {
  GCPCTL_FORMAT=table
  [ "$(core::bq_format)" = "pretty" ]
  GCPCTL_FORMAT=json
  [ "$(core::bq_format)" = "prettyjson" ]
}

@test "core::is_prod detecta proyectos de producción" {
  core::is_prod "acme-prod"
  core::is_prod "prd-datos"
  core::is_prod "data_production_eu"
  ! core::is_prod "acme-dev"
  ! core::is_prod "product-catalog"
}

@test "GCPCTL_PROD_PATTERN es configurable" {
  GCPCTL_PROD_PATTERN='^live-'
  core::is_prod "live-api"
  ! core::is_prod "acme-prod"
}

@test "core::validate_id acepta ids válidos y rechaza opciones" {
  run core::validate_id x "dataset_1"
  [ "$status" -eq 0 ]
  run core::validate_id x "proj:ds.tabla"
  [ "$status" -eq 0 ]
  run core::validate_id x "--project=otro"
  [ "$status" -eq 2 ]
  run core::validate_id x "con espacio"
  [ "$status" -eq 2 ]
  run core::validate_id x ""
  [ "$status" -eq 2 ]
}

@test "core::filter_quote escapa comillas y barras" {
  [ "$(core::filter_quote 'a"b')" = '"a\"b"' ]
  [ "$(core::filter_quote 'a\b')" = '"a\\b"' ]
}

@test "core::_build_cmd inserta extras antes de '--'" {
  local out=()
  core::_build_cmd out 1 --x gcloud run env -- -o json
  [ "${out[*]}" = "gcloud run env --x -- -o json" ]
  core::_build_cmd out 1 --x gcloud list
  [ "${out[*]}" = "gcloud list --x" ]
}

@test "core::confirm acepta 's' y rechaza otra respuesta" {
  export GCPCTL_FORCE_INTERACTIVE=1
  CORE_PROJECT=acme-dev
  run core::confirm "borrar" <<<"s"
  [ "$status" -eq 0 ]
  run core::confirm "borrar" <<<"n"
  [ "$status" -eq 130 ]
}

@test "core::confirm con --yes no pregunta fuera de producción" {
  GCPCTL_YES=1 CORE_PROJECT=acme-dev
  run core::confirm "op" </dev/null
  [ "$status" -eq 0 ]
}

@test "core::confirm en producción exige el ID del proyecto aunque haya --yes" {
  export GCPCTL_FORCE_INTERACTIVE=1
  GCPCTL_YES=1 CORE_PROJECT=acme-prod
  run core::confirm "op" <<<"s"
  [ "$status" -eq 130 ]
  run core::confirm "op" <<<"acme-prod"
  [ "$status" -eq 0 ]
}

@test "core::explain_error detecta API deshabilitada" {
  local f="${BATS_TEST_TMPDIR}/err"
  printf 'ERROR: PERMISSION_DENIED: Compute Engine API has not been used ... compute.googleapis.com\n  reason: SERVICE_DISABLED\n' >"$f"
  CORE_PROJECT=p1
  run core::explain_error "$f" 1
  [ "$status" -eq 4 ]
  [[ "$output" == *"gcloud services enable compute.googleapis.com --project p1"* ]]
}

@test "core::explain_error detecta credenciales caducadas" {
  local f="${BATS_TEST_TMPDIR}/err"
  printf 'ERROR: Reauthentication failed.\n' >"$f"
  run core::explain_error "$f" 1
  [ "$status" -eq 4 ]
  [[ "$output" == *"gcloud auth login"* ]]
}

@test "core::explain_error detecta permisos insuficientes" {
  local f="${BATS_TEST_TMPDIR}/err"
  printf 'ERROR: (gcloud.x) [u] does not have permission to access projects\n' >"$f"
  run core::explain_error "$f" 1
  [ "$status" -eq 4 ]
  [[ "$output" == *"Permisos IAM"* ]]
}

@test "core::gcloud en dry-run no ejecuta y cita los argumentos" {
  GCPCTL_DRY_RUN=1 CORE_PROJECT=p1
  run core::gcloud logging read 'severity>=ERROR AND "x y"'
  [ "$status" -eq 0 ]
  [[ "$output" == "[dry-run] gcloud logging read "* ]]
  [ ! -s "$STUB_LOG" ]
}
