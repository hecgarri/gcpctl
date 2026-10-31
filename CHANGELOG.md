# Changelog

## 0.1.0 — 2026-10-31

Primera versión.

- Dispatcher con opciones globales (`--project`, `--format`, `--region`, `--location`,
  `--zone`, `--yes`, `--dry-run`, `--quiet`, `--debug`, `--no-color`), ayuda generada,
  `help --all` y autocompletado de Bash.
- Módulos: projects, config, bigquery, composer, dataplex, compute, cloudrun, iam,
  logging y doctor.
- Menú interactivo con fzf (búsqueda incremental) o menú numerado de respaldo.
- Confirmación de operaciones de escritura y protección reforzada en producción.
- Traducción de errores de gcloud/bq a mensajes accionables.
- Instalador/desinstalador y suite de pruebas bats con stubs.
