APP_NAME = BetterBattery
BUNDLE_ID = com.betterbattery.app
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
INSTALL_DIR = /Applications
SOURCES = $(wildcard Sources/*.swift)

# Stable signing identity: first "Apple Development" certificate in the keychain,
# falling back to ad-hoc ("-"). A stable identity keeps the code signature's designated
# requirement identical across rebuilds, so Keychain items (SMC hash) stay accessible
# without re-prompting for the login keychain password.
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $$2; exit}')
ifeq ($(SIGN_IDENTITY),)
SIGN_IDENTITY = -
endif

SWIFTC = swiftc
SWIFT_FLAGS = -O -whole-module-optimization -target arm64-apple-macosx12.0
FRAMEWORKS = -framework Cocoa -framework IOKit -framework UserNotifications

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
		codesign --force --sign "$(SIGN_IDENTITY)" --entitlements BetterBattery.entitlements --options runtime $(APP_BUNDLE) || \
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
	@security delete-generic-password -s com.betterbattery.smc-hash >/dev/null 2>&1 || true
	@rm -rf ~/Library/Application\ Support/BetterBattery
	@defaults delete $(BUNDLE_ID) >/dev/null 2>&1 || true
	@echo "Uninstalled (app, LaunchAgent, sudoers, Keychain item, history, preferences)."

clean:
	@rm -rf $(BUILD_DIR)
	@echo "Cleaned."

release:
	@./scripts/release.sh

init-github:
	@./scripts/init-github.sh
