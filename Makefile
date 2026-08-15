APP     = Hisingen.app
BINARY  = .build/release/Hisingen
DMG     = Hisingen.dmg
ZIP     = Hisingen.zip
RESOURCE_BUNDLE = Hisingen_Hisingen.bundle

# Code-signing identity. Default "-" is ad-hoc (local builds); CI passes a
# "Developer ID Application: …" identity for notarized releases.
IDENTITY ?= -
SWIFT_FLAGS ?=

.PHONY: doctor build universal app app-universal dmg run test clean release

doctor:
	sh Scripts/doctor.sh

## Build the release binary
build: doctor
	swift build -c release $(SWIFT_FLAGS)

## Build a universal binary for distribution. Separate scratch directories
## avoid SwiftPM reusing artifacts from the other target architecture.
universal: doctor
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
	@echo "⚠️  Self-signed (ad-hoc) build — this identity changes on every rebuild, so macOS will re-prompt for Keychain/Accessibility access each time you rebuild. Pass IDENTITY=\"<your cert name>\" with a local self-signed certificate for a stable identity across rebuilds, or use the notarized release build for daily use."
else
ifneq (,$(findstring Developer ID,$(IDENTITY)))
	codesign --force --options runtime --timestamp -s "$(IDENTITY)" $(APP)
	@echo "✅ Signed with Developer ID identity \"$(IDENTITY)\" — production signing (notarize + staple via the release workflow before distributing)."
else
	codesign --force --options runtime --timestamp -s "$(IDENTITY)" $(APP)
	@echo "⚠️  Self-signed build using local identity \"$(IDENTITY)\" — not a Developer ID certificate. Stable across rebuilds (Keychain/Accessibility grants persist), but Gatekeeper still flags it as from an unidentified developer."
endif
endif
	@echo "Done → open $(APP)  (or move it to /Applications)"

app-universal: universal
	$(MAKE) app SKIP_BUILD=1 IDENTITY="$(IDENTITY)"

## Package the existing bundle as a drag-to-Applications disk image.
## Deliberately NOT dependent on `app`: that target is phony, and re-running
## it in CI after notarization would re-sign the bundle and void the staple.
dmg:
	@test -d $(APP) || { echo "No $(APP) — run 'make app' first"; exit 1; }
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

test: doctor
	sh Scripts/test.sh

clean:
	rm -rf .build .build-arm64 .build-x86_64 $(APP) $(DMG) $(ZIP) dmg-staging SHA256SUMS notarize-app.zip

## Cut a release: make release VERSION=2.5.0
## Bumps Info.plist, commits, tags v2.5.0, pushes — GitHub Actions then
## builds, packages and publishes the DMG/zip.
release:
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=x.y.z"; exit 1; }
	@echo "$(VERSION)" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$' || { echo "VERSION must be x.y.z"; exit 1; }
	@test -z "$$(git status --porcelain=v1)" || { echo "working tree not clean (including untracked files)"; exit 1; }
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" Resources/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $$(( $$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist) + 1 ))" Resources/Info.plist
	git commit -am "Release v$(VERSION)"
	git tag "v$(VERSION)"
	git push origin HEAD "v$(VERSION)"
	@echo "Done → GitHub Actions is building the release"
