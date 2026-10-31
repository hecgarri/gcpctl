# gcpctl

CLI modular en Bash para administrar proyectos y recursos de Google Cloud desde
la terminal, usando `gcloud` y `bq` como backend. Funciona en dos modos que
comparten **exactamente** la misma lógica:

- **CLI**: `gcpctl projects list`, `gcpctl bigquery datasets`, `gcpctl config show`…
- **Interactivo (TUI)**: `gcpctl` sin argumentos abre un menú navegable con
  búsqueda incremental (`fzf`), o un menú numerado si `fzf` no está instalado.

Reutiliza la autenticación existente de Google Cloud CLI: no guarda ni gestiona
credenciales.

---

## Arquitectura

```text
gcpctl/
├── bin/gcpctl          Dispatcher: opciones globales → módulo → acción
├── lib/
│   ├── core.sh         Logging, errores, dependencias, contexto, ejecución segura de gcloud/bq, confirmaciones
│   ├── registry.sh     Registro declarativo de módulos y acciones (read / write / interactive)
│   ├── projects.sh     Módulos 'projects' y 'config'
│   ├── bigquery.sh  composer.sh  dataplex.sh  compute.sh  cloudrun.sh (servicios y jobs)
│   ├── artifacts.sh  builds.sh  scheduler.sh  storage.sh  pubsub.sh  secrets.sh
│   ├── iam.sh  logging.sh
│   └── doctor.sh       Diagnóstico de dependencias, cuenta, proyecto y APIs
├── ui/
│   ├── picker.sh       Primitivas de selección/entrada (fzf → gum → read)
│   └── menu.sh         Árbol de menús generado desde el registro
├── tests/              bats-core + stubs de gcloud/bq (sin llamadas reales)
├── install.sh  uninstall.sh  Makefile  VERSION
```

### Cómo funciona el dispatcher

```text
gcpctl [opciones globales] <módulo> <acción> [args]
   │
   ├─ resuelve GCPCTL_HOME con readlink -f (funciona vía enlace simbólico)
   ├─ carga lib/core.sh, lib/registry.sh y los módulos (sólo definen funciones)
   ├─ extrae las opciones globales en cualquier posición (antes de '--')
   ├─ resuelve alias (bq → bigquery, run → cloudrun, gce → compute, logs → logging…)
   ├─ valida módulo/acción contra el registro y comprueba dependencias
   └─ registry::run módulo acción args
         └─ <módulo>::<acción> args  → core::gcloud / core::bq
```

Decisiones de diseño respecto a la estructura propuesta:

- **`lib/registry.sh` (añadido)**: cada módulo declara sus acciones con
  `registry::action módulo acción read|write|interactive "descripción" "uso" "args_tui"`.
  De esos metadatos se generan la ayuda, `help --all`, el autocompletado y el
  menú interactivo. Añadir una acción no exige tocar la UI.
- **`ui/picker.sh` (añadido)**: aísla el backend de selección (fzf / básico) y
  `gum` para entradas/confirmaciones; `menu.sh` no sabe qué backend se usa.
- **La TUI ejecuta el propio dispatcher como proceso hijo** (con el contexto en
  variables de entorno) en lugar de llamar a funciones de `lib/` en el mismo
  proceso. Motivo: Bash desactiva `set -e` dentro de funciones invocadas en
  contextos `||`/`if`, por lo que ejecutar las acciones *in-process* desde un
  menú sería frágil. Así cada operación tiene `set -euo pipefail` completo, la
  TUI se comporta igual que la CLI y un fallo nunca cierra el menú.
- `projects` y `config` comparten `projects.sh` por estar muy relacionados; el
  diagnóstico vive en `doctor.sh`.

### Seguridad y robustez

- Sin `eval`: todos los comandos se construyen como arrays; `--dry-run` los
  imprime citados con `printf %q`.
- Los identificadores se validan (no se aceptan valores que empiecen por `-`, ni
  espacios) para evitar inyección de opciones.
- Los filtros de Cloud Logging/IAM se escapan y se pasan como un único argumento.
- `gcloud` se ejecuta con `--quiet` (sin prompts ocultos); `stderr` se captura y
  se traduce a mensajes accionables: API deshabilitada (con el comando
  `gcloud services enable` exacto), permisos IAM insuficientes, credenciales
  caducadas, recurso inexistente, comando no soportado por la versión del SDK.
- **Lectura vs. escritura**: las acciones `write` piden confirmación. En
  proyectos de **producción** (regex `GCPCTL_PROD_PATTERN`, por defecto
  `prod`/`prd`/`production` como segmento del ID) hay que escribir el ID del
  proyecto, incluso con `--yes`; sin terminal la operación se rechaza salvo
  `GCPCTL_FORCE_PROD=1`.
- `--project` sólo afecta a la invocación actual; la configuración global de
  gcloud únicamente cambia con `projects use` / `config …` (acciones de escritura).

Códigos de salida: `0` ok · `1` error · `2` uso incorrecto · `3` dependencia o
versión del SDK · `4` API deshabilitada / permisos / autenticación · `130` cancelado.

---

## Requisitos

| Obligatorio | Opcional |
|---|---|
| Linux, Bash ≥ 4.4 | `fzf` (búsqueda incremental en la TUI) |
| [Google Cloud CLI](https://cloud.google.com/sdk/docs/install) (`gcloud`) | `gum` (entradas/confirmaciones más cómodas) |
| `jq` | `column` (util-linux), `bq` (incluido en Google Cloud CLI) |

Autenticación previa: `gcloud auth login` (y opcionalmente `gcloud config set project <ID>`).

APIs que usa cada módulo (las comprueba `gcpctl doctor`):

| Módulo | API | Roles orientativos (lectura) |
|---|---|---|
| projects | cloudresourcemanager.googleapis.com | `roles/browser` |
| bigquery | bigquery.googleapis.com | `roles/bigquery.metadataViewer`, `roles/bigquery.jobUser` (jobs propios), `roles/bigquery.resourceViewer` (`--all-users`) |
| composer | composer.googleapis.com | `roles/composer.user` (y `environments run` para listar DAGs) |
| dataplex | dataplex.googleapis.com | `roles/dataplex.dataScanViewer` / `dataScanDataViewer`, `roles/dataplex.catalogViewer` |
| compute | compute.googleapis.com | `roles/compute.viewer`; para SSH por IAP `roles/iap.tunnelResourceAccessor` |
| cloudrun | run.googleapis.com | `roles/run.viewer`; `execute` requiere `roles/run.invoker`/`run.developer` |
| artifacts | artifactregistry.googleapis.com | `roles/artifactregistry.reader` |
| builds | cloudbuild.googleapis.com | `roles/cloudbuild.builds.viewer` |
| scheduler | cloudscheduler.googleapis.com | `roles/cloudscheduler.viewer` (`run`/`pause`/`resume`: `cloudscheduler.admin`) |
| storage | storage.googleapis.com | `roles/storage.objectViewer` / `storage.bucketViewer` |
| pubsub | pubsub.googleapis.com | `roles/pubsub.viewer` |
| secrets | secretmanager.googleapis.com | `roles/secretmanager.viewer` (sólo metadatos) |
| iam | iam.googleapis.com | `roles/iam.securityReviewer` |
| logging | logging.googleapis.com | `roles/logging.viewer` |

---

## Instalación

```bash
git clone https://github.com/hecgarri/gcpctl.git
cd gcpctl
./install.sh                # ~/.local/share/gcpctl + enlace en ~/.local/bin/gcpctl
# o bien
sudo ./install.sh --system  # /opt/gcpctl + /usr/local/bin/gcpctl
```

Opciones: `--prefix DIR`, `--bin-dir DIR`, `--no-completion`, `--force`. El
instalador es idempotente, no sobrescribe directorios ni ejecutables ajenos sin
`--force`, avisa si el directorio del enlace no está en el `PATH` e instala el
autocompletado de Bash.

También se puede usar sin instalar: `./bin/gcpctl …`.

Desinstalación (no toca `~/.config/gcloud` ni recursos de GCP):

```bash
./uninstall.sh              # mismas opciones --prefix / --bin-dir / --system
```

Autocompletado manual: `source <(gcpctl completion bash)`.

---

## Uso

### Modo CLI

```bash
gcpctl doctor                                   # dependencias, cuenta, proyecto y APIs
gcpctl projects list
gcpctl projects current
gcpctl projects whoami
gcpctl projects use mi-proyecto-dev             # escritura: pide confirmación
gcpctl config list
gcpctl config show -f json

gcpctl bigquery datasets --project analitica-prod
gcpctl bq tables ventas
gcpctl bq show ventas.pedidos                   # metadatos + esquema (anidado)
gcpctl bq jobs --all-users --limit 50

gcpctl composer list --location europe-west1
gcpctl composer dags mi-entorno --location europe-west1 -f json

gcpctl dataplex scans --location europe-west1
gcpctl dataplex scan dq-clientes
gcpctl dataplex jobs dq-clientes
gcpctl dataplex result dq-clientes              # última ejecución: reglas, dimensiones, ratios
gcpctl dataplex entry-groups --location europe-west1
gcpctl dataplex search "clientes"

gcpctl compute list --zone europe-west1-b
gcpctl compute status vm-1                      # la zona se descubre si no se indica
gcpctl compute stop vm-1                        # escritura: pide confirmación
gcpctl compute ssh vm-1 --iap                   # IAP automático si no tiene IP externa

gcpctl run list
gcpctl run status api --region europe-west1
gcpctl run jobs                                 # jobs de todas las regiones
gcpctl run job etl-diario                       # imagen, tareas y última ejecución
gcpctl run executions etl-diario --limit 5
gcpctl run execution etl-diario-x7k2p
gcpctl run execute etl-diario --wait            # escritura: pide confirmación

gcpctl ar repos --location southamerica-west1
gcpctl ar images mi-repo                        # imágenes Docker con tags
gcpctl ar packages mi-repo
gcpctl ar versions mi-repo mi-paquete

gcpctl builds list --ongoing
gcpctl builds log 1a2b3c4d-...
gcpctl builds triggers

gcpctl scheduler locations
gcpctl scheduler list --location southamerica-east1
gcpctl scheduler run diario --location southamerica-east1   # escritura

gcpctl storage buckets
gcpctl gcs ls gs://mi-bucket/datos --recursive
gcpctl gcs du gs://mi-bucket

gcpctl secrets list                             # nunca muestra valores
gcpctl secrets versions db-url
gcpctl pubsub topics
gcpctl pubsub subscriptions eventos

gcpctl iam policy --member user:ana@example.com
gcpctl iam sa
gcpctl iam sa-keys sa@proyecto.iam.gserviceaccount.com

gcpctl logging read --severity WARNING --service run --freshness 2h
gcpctl logging read --text "timeout" --label service_name=api
gcpctl logs errors --freshness 6h -f json | jq length

gcpctl --dry-run compute start vm-1 --zone europe-west1-b   # muestra el comando sin ejecutarlo
```

### Modo interactivo

```bash
gcpctl          # o: gcpctl menu
```

- La cabecera muestra proyecto (con aviso ⚠ si es producción), cuenta, formato y ubicación.
- Módulo → acción → selección de recursos (datasets → tablas, entornos, DataScans →
  ejecuciones, instancias, servicios, cuentas de servicio…). Las listas se
  obtienen de la propia CLI en JSON, con búsqueda incremental en `fzf`.
- `Esc` (fzf) o `0` (menú básico) vuelve al nivel anterior. En el menú básico,
  escribir texto filtra la lista.
- Las acciones de escritura están marcadas con ✎ y piden confirmación.
- “Cambiar proyecto” afecta sólo a la sesión, con la opción de persistirlo.

### Opciones globales

| Opción | Descripción |
|---|---|
| `-p, --project ID` | Proyecto para esta invocación (no modifica gcloud) |
| `-f, --format` | `table` (por defecto), `json`, `yaml`, `csv` |
| `--region`, `--location`, `--zone` | Ubicación para Cloud Run / Dataplex / Composer / Compute |
| `-y, --yes` | Omite confirmaciones (salvo en producción) |
| `--dry-run` | Imprime los comandos `gcloud`/`bq` sin ejecutarlos |
| `-q, --quiet` · `--debug` · `--no-color` | Verbosidad y colores |
| `-h, --help` · `-V, --version` | Ayuda y versión |

Variables de entorno equivalentes: `GCPCTL_PROJECT`, `GCPCTL_FORMAT`,
`GCPCTL_REGION`, `GCPCTL_ZONE`, `GCPCTL_LOCATION`, `GCPCTL_PROD_PATTERN`,
`GCPCTL_PICKER=fzf|basic`, `NO_COLOR`.

Resolución de la ubicación: `--location`/`--region` → propiedad de gcloud
(`composer/location`, `artifacts/location`, `run/region`, `compute/region`, `compute/zone`) →
descubrimiento por nombre (Compute, servicios y jobs de Cloud Run) → error con instrucciones.

Notas:
- Artifact Registry exige ubicación porque listar en todas puede tardar minutos;
  usa `artifacts/location` o, en su defecto, `run/region`.
- Cloud Scheduler no está disponible en todas las regiones (p. ej. sus trabajos
  pueden estar en `southamerica-east1` aunque el job de Cloud Run esté en
  `southamerica-west1`): consulta `gcpctl scheduler locations`.
- Cloud Build y Cloud Storage son globales por defecto.

---

## Referencia de comandos

La referencia completa y siempre actualizada se genera desde el registro:

```bash
gcpctl help --all
gcpctl help <módulo> [acción]
```

| Módulo (alias) | Acciones |
|---|---|
| `projects` (project) | `list`, `current`, `use`✎, `describe`, `whoami`, `regions [--all]`, `zones` |
| `config` (configs) | `list`, `show`, `activate`✎, `create`✎, `set`✎, `unset`✎ |
| `bigquery` (bq) | `datasets`, `dataset`, `tables`, `show`, `jobs` |
| `composer` (airflow) | `list`, `describe`, `dags` |
| `dataplex` (catalog) | `scans`, `scan`, `jobs`, `result`, `entry-groups`, `entries`, `search` |
| `compute` (gce) | `list`, `status`, `start`✎, `stop`✎, `ssh`⇄ |
| `cloudrun` (run) | `list`, `describe`, `status`, `revisions`, `jobs`, `job`, `executions`, `execution`, `execute`✎ |
| `artifacts` (ar) | `repos`, `repo`, `images`, `packages`, `versions` |
| `builds` (cloudbuild, build) | `list`, `describe`, `log`, `triggers` |
| `scheduler` (cron) | `locations`, `list`, `describe`, `run`✎, `pause`✎, `resume`✎ |
| `storage` (gcs) | `buckets`, `bucket`, `ls`, `du` |
| `pubsub` (ps) | `topics`, `subscriptions`, `subscription` |
| `secrets` (secret) | `list`, `describe`, `versions` (sin acceso a valores) |
| `iam` | `policy`, `sa`, `sa-keys`, `sa-policy` |
| `logging` (logs) | `read`, `errors`, `services` |
| `doctor` | `check` (por defecto) |

✎ escritura (pide confirmación) · ⇄ interactiva.

Comandos de gcloud usados (verificados con Google Cloud SDK 590):
`projects list/describe/get-iam-policy`, `config …`, `auth list`,
`compute regions|zones|instances list/describe/start/stop`, `compute ssh --tunnel-through-iap`,
`compute firewall-rules list`, `composer environments list/describe/run … dags list`,
`dataplex datascans list/describe --view=FULL`, `dataplex datascans jobs list/describe --view=FULL`,
`dataplex entry-groups list`, `dataplex entries list/search`, `run services list/describe`,
`run revisions list`, `run jobs list/describe/execute`, `run jobs executions list/describe`,
`artifacts repositories list/describe`, `artifacts docker images list --include-tags`,
`artifacts packages|versions list`, `builds list/describe/log`, `builds triggers list`,
`scheduler locations list`, `scheduler jobs list/describe/run/pause/resume`,
`storage buckets list/describe`, `storage ls/du`, `pubsub topics|subscriptions list/describe`,
`secrets list/describe`, `secrets versions list`, `iam service-accounts list/get-iam-policy`, `iam service-accounts keys list`,
`logging read`, `services list --enabled`; y `bq ls [--datasets|--jobs]`, `bq show`.

---

## Añadir un módulo

1. Crea `lib/<modulo>.sh`:

   ```bash
   #!/usr/bin/env bash
   # lib/pubsub.sh — Pub/Sub: temas y suscripciones.

   registry::module pubsub "Pub/Sub: temas y suscripciones" "pubsub.googleapis.com"
   registry::alias ps pubsub
   registry::action pubsub topics read "Lista los temas"
   registry::action pubsub delete-topic write "Elimina un tema" "<TEMA>" "text:Tema"

   # Lista los temas del proyecto.
   pubsub::topics() {
     core::ensure_project
     core::gcloud pubsub topics list "$(core::gcloud_format 'table(name.basename():label=TOPIC)')"
   }

   # Elimina un tema (acción de escritura: confirma antes).
   pubsub::delete_topic() {
     core::validate_id TEMA "${1:-}"
     core::ensure_project
     registry::confirm_write "eliminar el tema $1"
     core::gcloud pubsub topics delete "$1"
   }
   ```

2. (Opcional) añade su nombre a `GCPCTL_MODULE_ORDER` en `bin/gcpctl` para fijar
   su posición; si no, se carga automáticamente al final.
3. Si declara un tipo de argumento nuevo para la TUI (p. ej. `"topic"`), crea
   `menu::ask_topic` en `ui/menu.sh` (una prueba lo verifica).
4. Añade pruebas en `tests/modules.bats` comprobando el comando enviado al stub.

Reglas: las funciones de `lib/` no leen de la terminal (salvo `registry::confirm_write`),
usan siempre `core::gcloud`/`core::bq`, respetan `GCPCTL_FORMAT` mediante
`core::gcloud_format` y validan sus argumentos.

---

## Pruebas y calidad

```bash
make test-deps   # descarga bats-core v1.11.0 en tests/lib/ (si no está instalado)
make test        # bats tests/
make lint        # shellcheck
make fmt-check   # shfmt -i 2 -ci -d
make check       # todo lo anterior
```

Las pruebas usan stubs de `gcloud` y `bq` (`tests/stubs/`) que registran cada
invocación y devuelven respuestas controladas, por lo que **nunca** contactan con
Google Cloud ni modifican tu configuración (`CLOUDSDK_CONFIG` apunta a un
directorio temporal). Cubren el dispatcher, el núcleo (formatos, validación,
confirmaciones, detección de producción, traducción de errores), los comandos
exactos de cada módulo, el selector básico de la TUI y el instalador.
