APP     = Hisingen.app
BINARY  = .build/release/Hisingen
DMG     = Hisingen.dmg
ZIP     = Hisingen.zip
RESOURCE_BUNDLE = Hisingen_Hisingen.bundle

# Code-signing identity resolution.
# Auto-detects local developer certificate or provisions "Hisingen Development"
# so macOS remembers Keychain & Accessibility permissions across rebuilds.
AUTODETECTED_IDENTITY := $(shell security find-identity -p codesigning 2>/dev/null | grep -E '"(Developer ID Application|Apple Development|Hisingen Development)' | head -n1 | sed -E 's/.*"([^"]+)".*/\1/')
IDENTITY ?= $(if $(AUTODETECTED_IDENTITY),$(AUTODETECTED_IDENTITY),Hisingen Development)
SWIFT_FLAGS ?=

.PHONY: all dist doctor build universal app app-universal dmg run test clean release setup-cert inject-secrets

## Default target: build both .app bundle and .dmg installer
all: app dmg

dist: app dmg

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
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BINARY) $(APP)/Contents/MacOS/Hisingen
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp Resources/Hisingen.icns $(APP)/Contents/Resources/Hisingen.icns
	mkdir -p $(APP)/Contents/Resources/$(RESOURCE_BUNDLE)
	cp -R Sources/Hisingen/Resources/. $(APP)/Contents/Resources/$(RESOURCE_BUNDLE)/
	cp -R Sources/Hisingen/Resources/. $(APP)/Contents/Resources/
ifeq ($(IDENTITY),-)
	codesign --force -s - $(APP)
	@echo "⚠️  Self-signed (ad-hoc) build — this identity changes on every rebuild, so macOS will re-prompt for Keychain/Accessibility access each time you rebuild. Pass IDENTITY=\"<your cert name>\" or run 'make setup-cert' to avoid repeated prompts."
else
	@if ! security find-identity -p codesigning 2>/dev/null | grep -q "\"$(IDENTITY)\""; then \
		sh Scripts/setup-dev-cert.sh; \
	fi
ifneq (,$(findstring Developer ID,$(IDENTITY)))
	codesign --force --options runtime --timestamp -s "$(IDENTITY)" $(APP)
	@echo "✅ Signed with Developer ID identity \"$(IDENTITY)\" — production signing (notarize + staple via the release workflow before distributing)."
else
	codesign --force -s "$(IDENTITY)" $(APP)
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
	rm -rf dmg-staging $(DMG)
	mkdir dmg-staging
	cp -R $(APP) dmg-staging/
	ln -s /Applications dmg-staging/Applications
	hdiutil create -volname Hisingen -srcfolder dmg-staging -ov -format UDZO $(DMG)
	rm -rf dmg-staging
	@echo "Done → $(DMG)"

## Quick run without a bundle (launch-at-login disabled in this mode)
run:
	swift run

test: doctor inject-secrets
	sh Scripts/test.sh

clean:
	rm -rf .build .build-arm64 .build-x86_64 $(APP) $(DMG) $(ZIP) dmg-staging SHA256SUMS notarize-app.zip

## Cut a release: make release [VERSION=1.0.0 | patch | minor | major]
## Bumps Info.plist, commits, tags, pushes — GitHub Actions then
## builds, packages and publishes the DMG/zip.
release:
	sh Scripts/release.sh $(VERSION)
