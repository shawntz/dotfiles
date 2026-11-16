# Shawn's Dotfiles: everyday tasks. `make` (or `make help`) lists them.
# Each target is a thin call into swift or scripts/; the scripts take --help.

SWIFT  ?= swift
BINDIR ?= $(HOME)/.local/bin
CONFIG ?= config
MEDIA_DIR ?= $(ROOT)/build/media

# Works from anywhere: `make -C installer test` or `make -f installer/Makefile test`.
ROOT := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
PACKAGE := --package-path "$(ROOT)"
# The CLI must not update itself while make is using it.
NO_SELF_UPDATE := SHAWN_NO_SELF_UPDATE=1 SHAWN_NO_UPDATE=1

.DEFAULT_GOAL := help
.PHONY: help build test test-scripts validate app dmg notarize release publish install-cli run icon media lint clean

help: ## List the targets
	@echo "Shawn's Dotfiles. Targets:"
	@awk 'BEGIN { FS = ":.*## " } /^[a-z-]+:.*## / { printf "  make %-13s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo "Variables: SIGN_IDENTITY, CONFIGURATION, NOTARY_PROFILE, MEDIA_DIR, PYTHON (see scripts/*.sh --help)."

build: ## Debug build of the app, the CLI and the web-app shell
	$(SWIFT) build $(PACKAGE)

test: ## Run every test: the Swift package's, then the build scripts'
	$(SWIFT) test $(PACKAGE)
	"$(ROOT)/scripts/tests/run.sh"

test-scripts: ## Test the build scripts (fake signing tools; nothing leaves this Mac)
	"$(ROOT)/scripts/tests/run.sh"

validate: ## Check config/ with the built CLI, and that git keeps every file in it (what CI runs)
	$(SWIFT) build $(PACKAGE) --product shawn
	cd "$(ROOT)" && $(NO_SELF_UPDATE) .build/debug/shawn config validate $(CONFIG)
	cd "$(ROOT)" && scripts/check-config-gitignore.sh $(CONFIG)

app: ## Build and sign build/Shawn's Dotfiles.app (SIGN_IDENTITY=- for ad hoc)
	"$(ROOT)/scripts/build-app.sh"

dmg: app ## Build the app, then build/ShawnsDotfiles-<version>.dmg
	"$(ROOT)/scripts/make-dmg.sh"

notarize: ## Notarize and staple the 'make dmg' image (needs NOTARY_PROFILE; not the release image)
	"$(ROOT)/scripts/notarize.sh"

release: ## App, disk image, CLI tarball and manifest; prints the gh command
	"$(ROOT)/scripts/release.sh"

publish: ## Publish what 'make release' built as a GitHub release (CI does both on a version bump)
	"$(ROOT)/scripts/publish-release.sh"

install-cli: ## Build the CLI (release) and install it as ~/.local/bin/shawn
	$(SWIFT) build $(PACKAGE) -c release --product shawn
	install -d "$(BINDIR)"
	install -m 0755 "$$($(SWIFT) build $(PACKAGE) -c release --show-bin-path)/shawn" "$(BINDIR)/shawn"
	@echo "Installed $(BINDIR)/shawn. Make sure $(BINDIR) is on your PATH."

run: ## Open the installer in demo mode (a dry run: nothing on this Mac changes)
	$(SWIFT) run $(PACKAGE) ShawnsDotfiles --demo

icon: ## Redraw Resources/AppIcon.icns from scripts/make-icon.swift
	$(SWIFT) "$(ROOT)/scripts/make-icon.swift" "$(ROOT)/Resources/AppIcon.icns"

media: ## Draw the README's GIFs and stills of the app into build/media (needs Pillow)
	"$(ROOT)/scripts/make-media.sh" "$(MEDIA_DIR)"

lint: ## shellcheck the scripts and their tests; actionlint the CI workflow when installed
	shellcheck -x "$(ROOT)"/scripts/*.sh "$(ROOT)"/scripts/tests/*.sh "$(ROOT)"/scripts/tests/fakes/*
	@workflow="$(ROOT)/../.github/workflows/installer.yml"; \
	if ! command -v actionlint >/dev/null 2>&1; then echo "actionlint is not installed; skipped the workflow"; \
	elif [ -f "$$workflow" ]; then actionlint "$$workflow"; \
	else echo "no $$workflow; skipped"; fi

clean: ## Remove build products (swift package clean, and build/)
	$(SWIFT) package $(PACKAGE) clean
	rm -rf "$(ROOT)/build"
