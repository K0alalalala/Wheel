# One-word entry points for humans and coding agents. Requires macOS + Xcode.
# Uses /Applications/Xcode.app even if xcode-select points at the Command Line Tools.
SHELL := /bin/zsh
export DEVELOPER_DIR ?= $(shell if [[ -d /Applications/Xcode.app && "$$(xcode-select -p)" == *CommandLineTools* ]]; then echo /Applications/Xcode.app/Contents/Developer; else xcode-select -p; fi)

.PHONY: build test app run dmg check icon screenshots logs clean

build:            ## Compile everything (debug)
	swift build

test:             ## Run the unit tests
	swift test

app:              ## Build build/Wheel.app (debug, this Mac's arch)
	scripts/build-app.sh debug

run: app          ## Build and launch the debug app
	-pkill -x Wheel
	open build/Wheel.app

dmg:              ## Universal release build + privacy check + build/Wheel-<version>.dmg
	scripts/make-dmg.sh

check:            ## Everything CI checks: tests, privacy scan, credits guard
	swift test
	scripts/privacy-check.sh
	scripts/check-credits.sh

screenshots:      ## Re-render the README images into docs/images (synthetic samples, default settings)
	scripts/build-app.sh debug
	build/Wheel.app/Contents/MacOS/Wheel --readme-shots "$(CURDIR)/docs/images"

icon:             ## Regenerate Resources/AppIcon.icns
	swift scripts/make-icon.swift

logs:             ## Show where the local log is and its last 40 lines
	@echo "~/Library/Logs/Wheel"; ls -l ~/Library/Logs/Wheel 2>/dev/null || echo "(no logs yet)"
	@tail -n 40 ~/Library/Logs/Wheel/wheel.log 2>/dev/null || true

clean:
	rm -rf .build build
