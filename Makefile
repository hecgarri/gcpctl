# Makefile de gcpctl: análisis estático, formato y pruebas.
#
#   make lint        shellcheck
#   make fmt         aplica shfmt
#   make fmt-check   comprueba el formato sin modificar
#   make test        ejecuta bats (usa bats del sistema o tests/lib/bats-core)
#   make test-deps   descarga bats-core en tests/lib (no se versiona)
#   make check       lint + fmt-check + test

SHELL := /usr/bin/env bash
SCRIPTS := bin/gcpctl $(wildcard lib/*.sh ui/*.sh) install.sh uninstall.sh tests/stubs/gcloud tests/stubs/bq
SHFMT_FLAGS := -i 2 -ci
BATS_VERSION := v1.11.0
BATS := $(shell command -v bats 2>/dev/null || echo tests/lib/bats-core/bin/bats)

.PHONY: lint fmt fmt-check test test-deps check install uninstall

lint:
	shellcheck -x $(SCRIPTS)
	shellcheck -x -s bash tests/helpers/common.bash

fmt:
	shfmt $(SHFMT_FLAGS) -w $(SCRIPTS)

fmt-check:
	shfmt $(SHFMT_FLAGS) -d $(SCRIPTS)

test-deps:
	@test -x tests/lib/bats-core/bin/bats || \
	  git clone --depth 1 --branch $(BATS_VERSION) https://github.com/bats-core/bats-core.git tests/lib/bats-core

test:
	@test -x "$(BATS)" || { echo "bats no encontrado: ejecuta 'make test-deps'"; exit 3; }
	$(BATS) tests/

check: lint fmt-check test

install:
	./install.sh

uninstall:
	./uninstall.sh
