.PHONY: build bundle install run snapshot signing-cert clean

APP_NAME := AI Bar
BUNDLE := AI Bar.app
BUILD_DIR := .build/release

# Sign with the local certificate from `make signing-cert` when it is in the keychain, otherwise ad hoc.
SIGNING_IDENTITY ?= Local App Signing
SIGN_WITH := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q '"$(SIGNING_IDENTITY)"' && echo '$(SIGNING_IDENTITY)' || echo -)

build:
	swift build -c release

bundle: build
	rm -rf "$(BUNDLE)"
	mkdir -p "$(BUNDLE)/Contents/MacOS"
	mkdir -p "$(BUNDLE)/Contents/Resources"
	cp "$(BUILD_DIR)/AIBar" "$(BUNDLE)/Contents/MacOS/AIBar"
	cp Resources/Info.plist "$(BUNDLE)/Contents/"
	cp Resources/AppIcon.icns "$(BUNDLE)/Contents/Resources/"
	@if [ "$(SIGN_WITH)" = "-" ]; then echo "Signing ad hoc. Run 'make signing-cert' once to sign with a stable identity."; fi
	codesign --force --sign "$(SIGN_WITH)" "$(BUNDLE)"
	@echo "Built $(BUNDLE)"

install: bundle
	rm -rf "/Applications/$(BUNDLE)"
	cp -R "$(BUNDLE)" /Applications/
	@echo "Installed to /Applications/$(BUNDLE)"

run: bundle
	open "$(BUNDLE)"

snapshot:
	swift build
	$$(swift build --show-bin-path)/AIBar --snapshot docs

signing-cert:
	SIGNING_IDENTITY="$(SIGNING_IDENTITY)" scripts/create-signing-cert.sh

clean:
	swift package clean
	rm -rf "$(BUNDLE)"
