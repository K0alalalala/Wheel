# One-word entry points for humans and coding agents. Requires macOS + Xcode.
# Uses /Applications/Xcode.app even if xcode-select points at the Command Line Tools.
SHELL := /bin/zsh
export DEVELOPER_DIR ?= $(shell if [[ -d /Applications/Xcode.app && "$$(xcode-select -p)" == *CommandLineTools* ]]; then echo /Applications/Xcode.app/Contents/Developer; else xcode-select -p; fi)

.PHONY: build test app run dmg check icon clean

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

icon:             ## Regenerate Resources/AppIcon.icns
	swift scripts/make-icon.swift

clean:
	rm -rf .build build
