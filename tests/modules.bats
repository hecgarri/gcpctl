#!/usr/bin/env bats
# Pruebas de los módulos: verifican los comandos exactos enviados a gcloud/bq.

load helpers/common

setup() { gcpctl_setup; }

# --- projects / config ---

@test "projects list usa gcloud projects list" {
  run "$GCPCTL" projects list --limit 5
  [ "$status" -eq 0 ]
  assert_called "gcloud projects list --sort-by=projectId --limit=5"
}

@test "projects current en JSON indica el origen" {
  run "$GCPCTL" -p acme-prod -f json projects current
  [ "$status" -eq 0 ]
  [ "$(jq -r .project <<<"$output")" = "acme-prod" ]
  [ "$(jq -r .production <<<"$output")" = "true" ]
}

@test "projects use es escritura: sin --yes ni terminal se cancela" {
  run "$GCPCTL" projects use nuevo-proyecto </dev/null
  [ "$status" -eq 130 ]
  refute_called "config set project"
}

@test "projects use con --yes fija el proyecto" {
  run "$GCPCTL" --yes projects use nuevo-dev
  [ "$status" -eq 0 ]
  assert_called "gcloud config set project nuevo-dev"
}

@test "projects use en producción sin terminal se rechaza aunque haya --yes" {
  run "$GCPCTL" --yes projects use acme-prod </dev/null
  [ "$status" -eq 130 ]
  refute_called "config set project"
}

@test "config activate respeta --dry-run" {
  run "$GCPCTL" --dry-run config activate trabajo
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run] gcloud config configurations activate trabajo"* ]]
  refute_called "configurations activate"
}

@test "projects regions en JSON incluye las propiedades" {
  export STUB_PROP_compute_region=europe-west1
  run "$GCPCTL" -f json projects regions
  [ "$status" -eq 0 ]
  [ "$(jq -r '."compute/region"' <<<"$output")" = "europe-west1" ]
}

# --- bigquery ---

@test "bigquery datasets usa bq ls con el proyecto" {
  run "$GCPCTL" bigquery datasets
  [ "$status" -eq 0 ]
  assert_called "bq --headless --format=pretty --project_id=test-project ls --datasets --max_results=1000 test-project:"
}

@test "bigquery tables normaliza el dataset" {
  run "$GCPCTL" bigquery tables otro.ventas --limit 10
  [ "$status" -eq 0 ]
  assert_called "ls --max_results=10 otro:ventas"
}

@test "bigquery show resume el esquema en modo tabla" {
  export STUB_JSON='{"tableReference":{"projectId":"p","datasetId":"d","tableId":"t"},"type":"TABLE","numRows":"42","numBytes":"1048576","creationTime":"1700000000000","schema":{"fields":[{"name":"id","type":"INTEGER","mode":"REQUIRED"},{"name":"addr","type":"RECORD","fields":[{"name":"city","type":"STRING"}]}]}}'
  run "$GCPCTL" bigquery show d.t
  [ "$status" -eq 0 ]
  [[ "$output" == *"Filas:"*"42"* ]]
  [[ "$output" == *"addr.city"* ]]
  assert_called "show test-project:d.t"
}

@test "bigquery show rechaza referencias inválidas" {
  run "$GCPCTL" bigquery show a.b.c.d
  [ "$status" -eq 2 ]
}

@test "bigquery jobs --all-users usa --all" {
  run "$GCPCTL" bigquery jobs --all-users --limit 5
  [ "$status" -eq 0 ]
  assert_called "ls --jobs --all --max_results=5 test-project"
}

@test "errores de bq se traducen" {
  export STUB_FAIL="BigQuery error in ls operation: Not found: Dataset p:x"
  run "$GCPCTL" bigquery tables x
  [ "$status" -ne 0 ]
  [[ "$output" == *"El recurso no existe"* ]]
}

# --- composer ---

@test "composer requiere ubicación" {
  run "$GCPCTL" composer list
  [ "$status" -eq 2 ]
  [[ "$output" == *"--location"* ]]
}

@test "composer dags pasa -o tras '--' y el proyecto antes" {
  run "$GCPCTL" composer dags env1 --location europe-west1 -f json
  [ "$status" -eq 0 ]
  assert_called "gcloud composer environments run env1 --location=europe-west1 dags list --quiet --project=test-project -- -o json"
}

@test "composer usa composer/location como respaldo" {
  export STUB_PROP_composer_location=us-central1
  run "$GCPCTL" composer list
  [ "$status" -eq 0 ]
  assert_called "--locations=us-central1"
}

# --- dataplex ---

@test "dataplex scans usa la ubicación indicada" {
  run "$GCPCTL" dataplex scans --location europe-west1
  [ "$status" -eq 0 ]
  assert_called "gcloud dataplex datascans list --location=europe-west1"
}

@test "dataplex result resume la calidad de datos" {
  export STUB_JSON='{"name":"projects/p/locations/l/dataScans/s/jobs/j1","type":"DATA_QUALITY","state":"SUCCEEDED","dataQualityResult":{"passed":false,"score":75,"rowCount":"10","dimensions":[{"dimension":{"name":"COMPLETENESS"},"passed":false,"score":50}],"rules":[{"rule":{"column":"email","dimension":"COMPLETENESS","name":"no-nulos"},"passed":false,"evaluatedCount":"10","passedCount":"5","passRatio":0.5}]}}'
  run "$GCPCTL" dataplex result s j1 --location l
  [ "$status" -eq 0 ]
  [[ "$output" == *"NO SUPERADO"* ]]
  [[ "$output" == *"no-nulos"*"email"*"FALLO"*"50%"* ]]
  assert_called "jobs describe j1 --datascan=s --location=l --view=FULL"
}

@test "dataplex search pasa la consulta como un único argumento" {
  run "$GCPCTL" dataplex search "tabla clientes"
  [ "$status" -eq 0 ]
  assert_called "gcloud dataplex entries search tabla\\ clientes --limit=50"
}

# --- compute ---

@test "compute list filtra por zona" {
  run "$GCPCTL" compute list --zone europe-west1-b
  [ "$status" -eq 0 ]
  assert_called "--zones=europe-west1-b"
}

@test "compute stop pide confirmación" {
  run "$GCPCTL" compute stop vm1 --zone z1 </dev/null
  [ "$status" -eq 130 ]
  refute_called "instances stop"
}

@test "compute stop con --yes detiene la instancia" {
  run "$GCPCTL" -y compute stop vm1 --zone z1
  [ "$status" -eq 0 ]
  assert_called "gcloud compute instances stop vm1 --zone=z1 --quiet --project=test-project"
}

@test "compute ssh --iap usa --tunnel-through-iap" {
  run "$GCPCTL" --dry-run compute ssh vm1 --zone z1 --iap
  [ "$status" -eq 0 ]
  [[ "$output" == *"compute ssh vm1 --zone=z1 --tunnel-through-iap"* ]]
}

# --- cloudrun ---

@test "cloudrun list sin región lista todas" {
  run "$GCPCTL" run list
  [ "$status" -eq 0 ]
  assert_called "gcloud run services list --quiet"
  refute_called "--region"
}

@test "cloudrun status resume condiciones" {
  export STUB_JSON='{"metadata":{"name":"api","labels":{"cloud.googleapis.com/location":"europe-west1"}},"status":{"url":"https://api.run.app","latestReadyRevisionName":"api-0001","conditions":[{"type":"Ready","status":"True"}],"traffic":[{"revisionName":"api-0001","percent":100}]}}'
  run "$GCPCTL" cloudrun status api --region europe-west1
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://api.run.app"* && "$output" == *"Ready"* && "$output" == *"100%"* ]]
}

# --- iam ---

@test "iam policy aplana y filtra por miembro" {
  run "$GCPCTL" iam policy --member user:a@b.com
  [ "$status" -eq 0 ]
  assert_called "gcloud projects get-iam-policy test-project --flatten=bindings\\[\\].members"
  assert_called "bindings.members:"
}

@test "iam sa-keys valida la cuenta" {
  run "$GCPCTL" iam sa-keys
  [ "$status" -eq 2 ]
}

# --- logging ---

@test "logging read construye el filtro de severidad y servicio" {
  run "$GCPCTL" -f json logging read --severity warning --service run --freshness 2h --limit 5
  [ "$status" -eq 0 ]
  assert_called 'severity\>=WARNING\ AND\ resource.type=\"cloud_run_revision\"'
  assert_called "--freshness=2h --limit=5 --order=desc"
}

@test "logging errors usa ERROR y 1d por defecto" {
  run "$GCPCTL" logging errors
  [ "$status" -eq 0 ]
  assert_called 'severity\>=ERROR'
  assert_called "--freshness=1d"
}

@test "logging read rechaza severidades inválidas" {
  run "$GCPCTL" logging read --severity LOUD
  [ "$status" -eq 2 ]
}

@test "logging renderiza entradas en modo tabla" {
  export STUB_JSON='[{"timestamp":"2026-01-01T10:00:00.123Z","severity":"ERROR","resource":{"type":"cloud_run_revision"},"textPayload":"fallo\nmultilínea"}]'
  run "$GCPCTL" logging errors
  [ "$status" -eq 0 ]
  [[ "$output" == *"2026-01-01 10:00:00  ERROR"*"cloud_run_revision"*"fallo multilínea"* ]]
}

# --- cloudrun jobs ---

@test "cloudrun jobs lista los jobs de todas las regiones" {
  run "$GCPCTL" run jobs
  [ "$status" -eq 0 ]
  assert_called "gcloud run jobs list --quiet"
}

@test "cloudrun job descubre la región por nombre exacto" {
  export STUB_JSON='[{"metadata":{"name":"etl","labels":{"cloud.googleapis.com/location":"southamerica-west1"}},"spec":{"template":{"spec":{"taskCount":1,"template":{"spec":{"containers":[{"image":"img:1"}]}}}}},"status":{"executionCount":3,"latestCreatedExecution":{"name":"etl-abc","completionStatus":"EXECUTION_SUCCEEDED"}}},{"metadata":{"name":"etl-2","labels":{"cloud.googleapis.com/location":"us-central1"}}}]'
  run "$GCPCTL" -f yaml run job etl
  [ "$status" -eq 0 ]
  assert_called "gcloud run jobs describe etl --region=southamerica-west1"
}

@test "cloudrun execution deduce el job del nombre de la ejecución" {
  run "$GCPCTL" run execution etl-abc12 --region us-central1
  [ "$status" -eq 0 ]
  assert_called "gcloud run jobs executions describe etl-abc12 --region=us-central1"
}

@test "cloudrun execute es escritura y es asíncrono por defecto" {
  run "$GCPCTL" run execute etl --region r1 </dev/null
  [ "$status" -eq 130 ]
  refute_called "jobs execute"
  run "$GCPCTL" -y run execute etl --region r1
  [ "$status" -eq 0 ]
  assert_called "gcloud run jobs execute etl --region=r1 --async"
}

# --- artifacts ---

@test "artifacts usa run/region como ubicación de respaldo" {
  export STUB_PROP_run_region=southamerica-west1
  run "$GCPCTL" ar repos
  [ "$status" -eq 0 ]
  assert_called "gcloud artifacts repositories list --location=southamerica-west1"
}

@test "artifacts images construye la ruta del repositorio Docker" {
  run "$GCPCTL" ar images repo1 --location europe-west1 --limit 5
  [ "$status" -eq 0 ]
  assert_called "gcloud artifacts docker images list europe-west1-docker.pkg.dev/test-project/repo1 --include-tags"
  assert_called "--limit=5"
}

@test "artifacts versions exige repositorio y paquete" {
  run "$GCPCTL" ar versions repo1 --location l
  [ "$status" -eq 2 ]
  run "$GCPCTL" ar versions repo1 pkg --location l
  [ "$status" -eq 0 ]
  assert_called "--package=pkg --repository=repo1 --location=l"
}

# --- builds ---

@test "builds list es global salvo --region" {
  run "$GCPCTL" builds list --ongoing --limit 3
  [ "$status" -eq 0 ]
  assert_called "gcloud builds list --ongoing --limit=3"
  refute_called "--region"
  run "$GCPCTL" builds log abc-123 --region europe-west1
  [ "$status" -eq 0 ]
  assert_called "gcloud builds log abc-123 --region=europe-west1"
}

# --- scheduler ---

@test "scheduler run es escritura con ubicación" {
  run "$GCPCTL" -y scheduler run diario --location southamerica-east1
  [ "$status" -eq 0 ]
  assert_called "gcloud scheduler jobs run diario --location=southamerica-east1"
}

@test "scheduler pause pide confirmación" {
  run "$GCPCTL" scheduler pause diario --location l </dev/null
  [ "$status" -eq 130 ]
  refute_called "jobs pause"
}

# --- storage ---

@test "storage ls normaliza la URL y usa listado largo" {
  run "$GCPCTL" storage ls mi-bucket
  [ "$status" -eq 0 ]
  assert_called "gcloud storage ls gs://mi-bucket/ --long --readable-sizes"
  run "$GCPCTL" -f json storage ls gs://mi-bucket/datos --recursive
  [ "$status" -eq 0 ]
  assert_called "gcloud storage ls gs://mi-bucket/datos --recursive --json"
}

@test "storage bucket describe el bucket" {
  run "$GCPCTL" storage bucket gs://mi-bucket
  [ "$status" -eq 0 ]
  assert_called "gcloud storage buckets describe gs://mi-bucket"
}

# --- secrets / pubsub ---

@test "secrets no expone ninguna acción que lea valores" {
  run "$GCPCTL" help secrets
  [ "$status" -eq 0 ]
  [[ "$output" != *"access"* ]]
  run "$GCPCTL" secrets access algo
  [ "$status" -eq 2 ]
}

@test "secrets versions lista versiones" {
  run "$GCPCTL" secrets versions db-url
  [ "$status" -eq 0 ]
  assert_called "gcloud secrets versions list db-url"
}

@test "pubsub subscriptions filtra por tema" {
  run "$GCPCTL" pubsub subscriptions eventos
  [ "$status" -eq 0 ]
  assert_called 'topic:\"projects/test-project/topics/eventos\"'
}
