SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

.PHONY: help validate resolve test lint verify-inputs build smoke verify clean

help:
	@printf '%s\n' \
	  'validate  validate schemas, the matrix, and referenced locks' \
	  'resolve   print the fully resolved image/architecture matrix' \
	  'test      run repository contract tests' \
	  'lint      run ShellCheck over repository shell scripts' \
	  'verify-inputs  verify locked OS repository metadata (requires network)' \
	  'build     build one common image; set DISTRIBUTION and optional runner variables' \
	  'smoke     smoke an image; set IMAGE to its local reference' \
	  'verify    alias for the current common smoke/inspection suite' \
	  'clean     remove this project build root (outside the checkout)'

validate:
	@./scripts/validate-locks.sh

resolve:
	@./scripts/resolve-matrix.sh

test:
	@./tests/repository-contract.sh

lint:
	@command -v shellcheck >/dev/null || { echo 'error: shellcheck is required' >&2; exit 1; }
	@shellcheck scripts/*.sh scripts/lib/*.sh tests/*.sh tests/common/*.sh images/common/*.sh

verify-inputs:
	@for distribution in $$(jq -r '.distributions[].id' locks/image-matrix.json); do \
	  for architecture in $$(jq -r '.architectures[]' locks/image-matrix.json); do \
	    ./scripts/verify-os-repositories.sh \
	      --distribution "$$distribution" --architecture "$$architecture"; \
	  done; \
	done

build:
	@test -n "$(DISTRIBUTION)" || { echo 'error: set DISTRIBUTION=ubuntu-26.04 or almalinux-10' >&2; exit 2; }
	@args=(--distribution "$(DISTRIBUTION)"); \
	  if [[ -n "$(ARCHITECTURE)" ]]; then args+=(--architecture "$(ARCHITECTURE)"); fi; \
	  if [[ -n "$(RUNNER_IMAGE)" ]]; then args+=(--runner-image "$(RUNNER_IMAGE)"); fi; \
	  if [[ -n "$(RUNNER_SOURCE_DIGEST)" ]]; then args+=(--runner-source-digest "$(RUNNER_SOURCE_DIGEST)"); fi; \
	  ./scripts/build-images.sh "$${args[@]}"

smoke verify:
	@test -n "$(IMAGE)" || { echo 'error: set IMAGE to a local immutable image reference' >&2; exit 2; }
	@./scripts/smoke-images.sh --image "$(IMAGE)"

clean:
	@./scripts/clean-build-root.sh
