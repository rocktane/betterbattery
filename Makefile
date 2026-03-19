APP_NAME = BetterBattery
BUNDLE_ID = com.betterbattery.app
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
INSTALL_DIR = /Applications
SOURCES = $(wildcard Sources/*.swift)

SWIFTC = swiftc
SWIFT_FLAGS = -O -whole-module-optimization -target arm64-apple-macosx12.0
FRAMEWORKS = -framework Cocoa -framework IOKit

.PHONY: all build install uninstall clean release init-github

all: build

build: $(APP_BUNDLE)

$(APP_BUNDLE): $(SOURCES) Info.plist BetterBattery.entitlements
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	$(SWIFTC) $(SWIFT_FLAGS) $(FRAMEWORKS) $(SOURCES) -o $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	@cp Info.plist $(APP_BUNDLE)/Contents/Info.plist
	@xcrun actool Assets/Assets.xcassets --compile $(APP_BUNDLE)/Contents/Resources \
		--platform macosx --minimum-deployment-target 12.0 \
		--app-icon AppIcon --output-partial-info-plist $(BUILD_DIR)/partial.plist 2>/dev/null
	@which codesign >/dev/null 2>&1 && \
		codesign --force --sign - --entitlements BetterBattery.entitlements --options runtime $(APP_BUNDLE) || \
		echo "Warning: codesign not found, skipping hardened runtime"
	@echo "Built $(APP_BUNDLE)"

install: build
	@echo "Installing to $(INSTALL_DIR)/$(APP_NAME).app ..."
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@cp -R $(APP_BUNDLE) "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Installed. Launch from /Applications or Spotlight."

uninstall:
	@echo "Removing $(APP_NAME)..."
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@rm -f ~/Library/LaunchAgents/$(BUNDLE_ID).plist
	@sudo rm -f /etc/sudoers.d/battery
	@echo "Uninstalled."

clean:
	@rm -rf $(BUILD_DIR)
	@echo "Cleaned."

release:
	@./scripts/release.sh

init-github:
	@./scripts/init-github.sh
