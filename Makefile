OUTPUT_DIR ?= releases
APP     ?= $(OUTPUT_DIR)/Hisingen.app
BINARY  = .build/release/Hisingen
DMG     ?= $(OUTPUT_DIR)/Hisingen.dmg
ZIP     ?= $(OUTPUT_DIR)/Hisingen.zip
DMG_STAGING ?= $(OUTPUT_DIR)/dmg-staging
RESOURCE_BUNDLE = Hisingen_Hisingen.bundle
# Sparkle is a binary SwiftPM target. It is copied beside a normal build product, but a
# universal build uses separate scratch paths, so resolve it from whichever build produced it.
# Keep this recursively expanded: a clean `make app` resolves SwiftPM artifacts only after
# the `build` prerequisite has completed.
SPARKLE_FRAMEWORK = $(shell find .build .build-arm64 .build-x86_64 -type d -name Sparkle.framework -print 2>/dev/null | head -n 1)

# Code-signing identity resolution.
# Auto-detects local developer certificate or provisions "Hisingen Development"
# so macOS remembers Keychain & Accessibility permissions across rebuilds.
AUTODETECTED_IDENTITY := $(shell security find-identity -p codesigning 2>/dev/null | grep -E '"(Developer ID Application|Apple Development|Hisingen Development)' | head -n1 | sed -E 's/.*"([^"]+)".*/\1/')
IDENTITY ?= $(if $(AUTODETECTED_IDENTITY),$(AUTODETECTED_IDENTITY),Hisingen Development)
SWIFT_FLAGS ?=

.PHONY: all dist ci doctor build universal app app-universal dmg run test clean release setup-cert inject-secrets

## Default target: build both .app bundle and .dmg installer
all: app dmg

dist: app dmg

## Run the deterministic build and test validation used by pull requests.
## Complete concurrency checking and the Swift 6 language mode are declared in
## Package.swift, so every build path is checked without extra flags here.
ci: doctor inject-secrets
	swift build
	sh Scripts/test.sh --skip Live

doctor:
	sh Scripts/doctor.sh

inject-secrets:
	sh Scripts/inject-secrets.sh

setup-cert:
	sh Scripts/setup-dev-cert.sh

## Build the release binary
build: doctor inject-secrets
	swift build -c release $(SWIFT_FLAGS)

## Build a universal binary for distribution. Separate scratch directories
## avoid SwiftPM reusing artifacts from the other target architecture.
universal: doctor inject-secrets
	swift build -c release --arch arm64 --scratch-path .build-arm64 $(SWIFT_FLAGS)
	swift build -c release --arch x86_64 --scratch-path .build-x86_64 $(SWIFT_FLAGS)
	mkdir -p .build/release
	lipo -create \
		"$$(swift build -c release --arch arm64 --scratch-path .build-arm64 --show-bin-path)/Hisingen" \
		"$$(swift build -c release --arch x86_64 --scratch-path .build-x86_64 --show-bin-path)/Hisingen" \
		-output $(BINARY)
	lipo $(BINARY) -verify_arch arm64 x86_64

## Assemble a proper .app bundle (needed for launch-at-login) and sign it
app: $(if $(SKIP_BUILD),,build)
	plutil -lint Resources/Info.plist
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources $(APP)/Contents/Frameworks
	cp $(BINARY) $(APP)/Contents/MacOS/Hisingen
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	sh Scripts/configure-updater.sh $(APP)/Contents/Info.plist
	cp Resources/Hisingen.icns $(APP)/Contents/Resources/Hisingen.icns
	mkdir -p $(APP)/Contents/Resources/$(RESOURCE_BUNDLE)
	cp -R Sources/Hisingen/Resources/. $(APP)/Contents/Resources/$(RESOURCE_BUNDLE)/
	cp -R Sources/Hisingen/Resources/. $(APP)/Contents/Resources/
	@if [ -n "$(SPARKLE_FRAMEWORK)" ] && [ -d "$(SPARKLE_FRAMEWORK)" ]; then \
		cp -R "$(SPARKLE_FRAMEWORK)" "$(APP)/Contents/Frameworks/"; \
	else \
		echo "Sparkle.framework was not produced by SwiftPM" >&2; exit 1; \
	fi
	@if ! otool -l "$(APP)/Contents/MacOS/Hisingen" | grep -Fq '@executable_path/../Frameworks'; then \
		install_name_tool -add_rpath '@executable_path/../Frameworks' "$(APP)/Contents/MacOS/Hisingen"; \
	fi
ifeq ($(IDENTITY),-)
	codesign --force --deep -s - $(APP)
	@echo "⚠️  Self-signed (ad-hoc) build — this identity changes on every rebuild, so macOS will re-prompt for Keychain/Accessibility access each time you rebuild. Pass IDENTITY=\"<your cert name>\" or run 'make setup-cert' to avoid repeated prompts."
else
	@if ! security find-identity -p codesigning 2>/dev/null | grep -q "\"$(IDENTITY)\""; then \
		sh Scripts/setup-dev-cert.sh; \
	fi
ifneq (,$(findstring Developer ID,$(IDENTITY)))
	codesign --force --deep --options runtime --timestamp -s "$(IDENTITY)" $(APP)
	@echo "✅ Signed with Developer ID identity \"$(IDENTITY)\" — production signing (notarize + staple via the release workflow before distributing)."
else
	codesign --force --deep -s "$(IDENTITY)" $(APP)
	@echo "✅ Signed with stable local identity \"$(IDENTITY)\" — persistent across rebuilds (Keychain & Accessibility permissions remembered)."
endif
endif
	@echo "Done → open $(APP)  (or move it to /Applications)"

app-universal: universal
	$(MAKE) app SKIP_BUILD=1 IDENTITY="$(IDENTITY)"

## Package the existing bundle as a drag-to-Applications disk image.
dmg:
	@if [ ! -d "$(APP)" ]; then \
		echo "==> $(APP) not found, building it first..."; \
		$(MAKE) app IDENTITY="$(IDENTITY)"; \
	fi
	rm -rf $(DMG_STAGING) $(DMG)
	mkdir -p $(DMG_STAGING)
	cp -R $(APP) $(DMG_STAGING)/
	ln -s /Applications $(DMG_STAGING)/Applications
	hdiutil create -volname Hisingen -srcfolder $(DMG_STAGING) -ov -format UDZO $(DMG)
	rm -rf $(DMG_STAGING)
	@echo "Done → $(DMG)"

## Quick run without a bundle (launch-at-login disabled in this mode)
run:
	swift run

test: doctor inject-secrets
	sh Scripts/test.sh

clean:
	rm -rf .build .build-arm64 .build-x86_64 $(APP) $(DMG) $(ZIP) $(DMG_STAGING) SHA256SUMS notarize-app.zip
	@rmdir $(OUTPUT_DIR) 2>/dev/null || true

## Cut a release: make release [VERSION=1.0.0 | patch | minor | major]
## Bumps Info.plist, commits, tags, pushes — GitHub Actions then
## builds, packages and publishes the DMG/zip.
release:
	sh Scripts/release.sh $(VERSION)
