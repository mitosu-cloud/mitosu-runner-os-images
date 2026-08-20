SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

.PHONY: help validate resolve test lint clean

help:
	@printf '%s\n' \
	  'validate  validate schemas, the matrix, and referenced locks' \
	  'resolve   print the fully resolved image/architecture matrix' \
	  'test      run repository contract tests' \
	  'lint      run ShellCheck over repository shell scripts' \
	  'clean     remove this project build root (outside the checkout)'

validate:
	@./scripts/validate-locks.sh

resolve:
	@./scripts/resolve-matrix.sh

test:
	@./tests/repository-contract.sh

lint:
	@command -v shellcheck >/dev/null || { echo 'error: shellcheck is required' >&2; exit 1; }
	@shellcheck scripts/*.sh scripts/lib/*.sh tests/*.sh

clean:
	@./scripts/clean-build-root.sh
