SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

MITOSU_BUILD_ROOT ?= /tmp/mitosu-runner-os-images
TMPDIR := /tmp
export MITOSU_BUILD_ROOT TMPDIR

.PHONY: help validate resolve test lint verify-inputs build smoke verify publish runtime-pack sign-runtime-pack verify-runtime-pack clean

help:
	@printf '%s\n' \
	  'validate  validate schemas, the matrix, and referenced locks' \
	  'resolve   print the fully resolved image/architecture matrix' \
	  'test      run repository contract tests' \
	  'lint      run ShellCheck over repository shell scripts' \
	  'verify-inputs  verify locked OS repository metadata (requires network)' \
	  'build     build one common image; set DISTRIBUTION and optional runner variables' \
	  'smoke     smoke an image; set IMAGE to its local reference' \
	  'verify    run smoke, runner-byte, and stored-root inspection checks' \
	  'publish   build, verify, and push current images; set RELEASE_TAG and optional ARCHITECTURE' \
	  'runtime-pack  generate a consumer-compatible pack; set PACK_ID, KERNEL, RUNNER, INITFS, TOOL_IMAGE' \
	  'sign-runtime-pack  sign a pack; set RUNTIME_PACK_DIR, SIGNING_KEY, and RUNTIME_PACK_SOURCE' \
	  'verify-runtime-pack  verify a signed pack; set RUNTIME_PACK_DIR' \
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

smoke:
	@test -n "$(IMAGE)" || { echo 'error: set IMAGE to a local immutable image reference' >&2; exit 2; }
	@./scripts/smoke-images.sh --image "$(IMAGE)"

verify:
	@test -n "$(IMAGE)" || { echo 'error: set IMAGE to a local immutable image reference' >&2; exit 2; }
	@./scripts/verify-images.sh --image "$(IMAGE)"

publish:
	@test -n "$(RELEASE_TAG)" || { echo 'error: set RELEASE_TAG' >&2; exit 2; }
	@args=(--tag "$(RELEASE_TAG)"); \
	  if [[ -n "$(ARCHITECTURE)" ]]; then args+=(--architecture "$(ARCHITECTURE)"); fi; \
	  if [[ "$(ALLOW_EMULATED)" == 1 ]]; then args+=(--allow-emulated); fi; \
	  if [[ -n "$(REPOSITORY)" ]]; then args+=(--repository "$(REPOSITORY)"); fi; \
	  ./scripts/build-and-push-images.sh "$${args[@]}"

runtime-pack:
	@test -n "$(PACK_ID)" || { echo 'error: set PACK_ID' >&2; exit 2; }
	@test -n "$(KERNEL)" || { echo 'error: set KERNEL' >&2; exit 2; }
	@test -n "$(RUNNER)" || { echo 'error: set RUNNER' >&2; exit 2; }
	@test -n "$(INITFS)" || { echo 'error: set INITFS to an immutable OCI reference' >&2; exit 2; }
	@test -n "$(TOOL_IMAGE)" || { echo 'error: set TOOL_IMAGE to an immutable OCI reference' >&2; exit 2; }
	@args=( \
	  --output "$${MITOSU_BUILD_ROOT:-/tmp/mitosu-runner-os-images}/runtime-packs/$(PACK_ID)" \
	  --pack-id "$(PACK_ID)" \
	  --kernel "$(KERNEL)" \
	  --runner "$(RUNNER)" \
	  --initfs "$(INITFS)" \
	  --tool-image "$(TOOL_IMAGE)" \
	); \
	if [[ -n "$(IMAGE_SET)" ]]; then args+=(--image-set "$(IMAGE_SET)"); fi; \
	./scripts/generate-runtime-pack.sh "$${args[@]}"

sign-runtime-pack:
	@test -n "$(RUNTIME_PACK_DIR)" || { echo 'error: set RUNTIME_PACK_DIR' >&2; exit 2; }
	@test -n "$(SIGNING_KEY)" || { echo 'error: set SIGNING_KEY to an Ed25519 private-key path' >&2; exit 2; }
	@test -n "$(RUNTIME_PACK_SOURCE)" || { echo 'error: set RUNTIME_PACK_SOURCE to an HTTPS URL or absolute directory' >&2; exit 2; }
	@./scripts/sign-runtime-pack.sh \
	  --pack-dir "$(RUNTIME_PACK_DIR)" \
	  --private-key "$(SIGNING_KEY)" \
	  --source "$(RUNTIME_PACK_SOURCE)"

verify-runtime-pack:
	@test -n "$(RUNTIME_PACK_DIR)" || { echo 'error: set RUNTIME_PACK_DIR' >&2; exit 2; }
	@./scripts/verify-runtime-pack.sh --pack-dir "$(RUNTIME_PACK_DIR)"

clean:
	@./scripts/clean-build-root.sh
