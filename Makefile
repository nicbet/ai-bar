.PHONY: build bundle install run snapshot clean

APP_NAME := AI Bar
BUNDLE := AI Bar.app
BUILD_DIR := .build/release

build:
	swift build -c release

bundle: build
	rm -rf "$(BUNDLE)"
	mkdir -p "$(BUNDLE)/Contents/MacOS"
	mkdir -p "$(BUNDLE)/Contents/Resources"
	cp "$(BUILD_DIR)/AIBar" "$(BUNDLE)/Contents/MacOS/AIBar"
	cp Resources/Info.plist "$(BUNDLE)/Contents/"
	cp Resources/AppIcon.icns "$(BUNDLE)/Contents/Resources/"
	codesign --force --sign - "$(BUNDLE)"
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

clean:
	swift package clean
	rm -rf "$(BUNDLE)"
