#!/usr/bin/env bats
# Pruebas del dispatcher: ayuda, versión, errores de uso y opciones globales.

load helpers/common

setup() { gcpctl_setup; }

@test "--version muestra la versión del archivo VERSION" {
  run "$GCPCTL" --version
  [ "$status" -eq 0 ]
  [ "$output" = "gcpctl $(cat "${REPO_ROOT}/VERSION")" ]
}

@test "--help lista los módulos" {
  run "$GCPCTL" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"bigquery"* && "$output" == *"dataplex"* && "$output" == *"--project"* ]]
}

@test "sin argumentos y sin terminal muestra el uso y sale con 2" {
  run "$GCPCTL" </dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"Uso:"* ]]
}

@test "módulo desconocido sale con 2" {
  run "$GCPCTL" nope list
  [ "$status" -eq 2 ]
  [[ "$output" == *"desconocido"* ]]
}

@test "acción desconocida sale con 2 y lista las acciones" {
  run "$GCPCTL" bigquery nope
  [ "$status" -eq 2 ]
  [[ "$output" == *"datasets"* ]]
}

@test "módulo sin acción muestra su ayuda y sale con 2" {
  run "$GCPCTL" compute
  [ "$status" -eq 2 ]
  [[ "$output" == *"Acciones:"* ]]
}

@test "doctor tiene acción por defecto" {
  run "$GCPCTL" help doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"check"* ]]
}

@test "<módulo> <acción> --help muestra la ayuda de la acción sin ejecutar" {
  run "$GCPCTL" compute ssh --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--iap"* ]]
  [ ! -s "$STUB_LOG" ]
}

@test "los alias resuelven al módulo canónico" {
  run "$GCPCTL" bq datasets
  [ "$status" -eq 0 ]
  assert_called "bq --headless"
}

@test "--format inválido es un error de uso" {
  run "$GCPCTL" -f xml projects list
  [ "$status" -eq 2 ]
  [[ "$output" == *"Formato no soportado"* ]]
}

@test "--project se pasa a gcloud sin modificar la configuración" {
  run "$GCPCTL" --project otro-proyecto iam sa
  [ "$status" -eq 0 ]
  assert_called "--project=otro-proyecto"
  refute_called "config set"
}

@test "las opciones globales pueden ir después de la acción" {
  run "$GCPCTL" iam sa -p tras-accion
  [ "$status" -eq 0 ]
  assert_called "--project=tras-accion"
}

@test "--project rechaza valores sospechosos" {
  run "$GCPCTL" --project '--malo' iam sa
  [ "$status" -eq 2 ]
  [ ! -s "$STUB_LOG" ] || refute_called "iam service-accounts"
}

@test "sin proyecto configurado da un error claro" {
  export STUB_PROP_project=""
  run "$GCPCTL" iam sa
  [ "$status" -eq 2 ]
  [[ "$output" == *"No hay un proyecto activo"* ]]
}

@test "funciona a través de un enlace simbólico" {
  ln -s "$GCPCTL" "${BATS_TEST_TMPDIR}/gcpctl-link"
  run "${BATS_TEST_TMPDIR}/gcpctl-link" --version
  [ "$status" -eq 0 ]
}

@test "help --all genera la referencia completa" {
  run "$GCPCTL" help --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"━━ logging ━━"* && "$output" == *"sa-keys"* ]]
}

@test "completion bash genera una función de autocompletado válida" {
  run "$GCPCTL" completion bash
  [ "$status" -eq 0 ]
  bash -n <(printf '%s\n' "$output")
  [[ "$output" == *"complete -F _gcpctl gcpctl"* ]]
}
