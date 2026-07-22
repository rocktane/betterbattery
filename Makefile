APP_NAME = BetterBattery
BUNDLE_ID = com.betterbattery.app
HELPER_ID = com.betterbattery.helper
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
INSTALL_DIR = /Applications
APP_SOURCES = $(wildcard Sources/*.swift) $(wildcard Shared/*.swift)
HELPER_SOURCES = $(wildcard Helper/*.swift) $(wildcard Shared/*.swift)
CERT_HASH_FILE = $(BUILD_DIR)/CertHash.swift

# Self-signed code-signing identity (create with `make cert`)
CODESIGN_ID ?= BetterBattery Signing

SWIFTC = swiftc
SWIFT_FLAGS = -O -whole-module-optimization -target arm64-apple-macosx13.0
FRAMEWORKS = -framework Cocoa -framework IOKit -framework ServiceManagement -framework UserNotifications
HELPER_FRAMEWORKS = -framework IOKit -framework Security

.PHONY: all build cert install uninstall clean release init-github

all: build

cert:
	@./scripts/make-cert.sh "$(CODESIGN_ID)"

build: $(APP_BUNDLE)

$(CERT_HASH_FILE): FORCE
	@mkdir -p $(BUILD_DIR)
	@CERT_SHA1=$$(security find-certificate -c "$(CODESIGN_ID)" -Z 2>/dev/null | awk '/SHA-1/{print $$3}'); \
	if [ -z "$$CERT_SHA1" ]; then \
		echo "error: signing certificate '$(CODESIGN_ID)' not found. Run 'make cert' first."; \
		exit 1; \
	fi; \
	echo "let kPinnedCertSHA1 = \"$$CERT_SHA1\"" > $(CERT_HASH_FILE).tmp; \
	cmp -s $(CERT_HASH_FILE).tmp $(CERT_HASH_FILE) || mv $(CERT_HASH_FILE).tmp $(CERT_HASH_FILE); \
	rm -f $(CERT_HASH_FILE).tmp

FORCE:

$(APP_BUNDLE): $(APP_SOURCES) $(HELPER_SOURCES) $(CERT_HASH_FILE) Info.plist BetterBattery.entitlements Helper/com.betterbattery.helper.plist
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@mkdir -p $(APP_BUNDLE)/Contents/Library/LaunchDaemons
	$(SWIFTC) $(SWIFT_FLAGS) $(HELPER_FRAMEWORKS) $(HELPER_SOURCES) $(CERT_HASH_FILE) -o $(APP_BUNDLE)/Contents/MacOS/$(HELPER_ID)
	$(SWIFTC) $(SWIFT_FLAGS) $(FRAMEWORKS) $(APP_SOURCES) -o $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	@cp Info.plist $(APP_BUNDLE)/Contents/Info.plist
	@cp Helper/com.betterbattery.helper.plist $(APP_BUNDLE)/Contents/Library/LaunchDaemons/
	@xcrun actool Assets/Assets.xcassets --compile $(APP_BUNDLE)/Contents/Resources \
		--platform macosx --minimum-deployment-target 13.0 \
		--app-icon AppIcon --output-partial-info-plist $(BUILD_DIR)/partial.plist 2>/dev/null
	codesign --force --sign "$(CODESIGN_ID)" --identifier $(HELPER_ID) --options runtime $(APP_BUNDLE)/Contents/MacOS/$(HELPER_ID)
	codesign --force --sign "$(CODESIGN_ID)" --entitlements BetterBattery.entitlements --options runtime $(APP_BUNDLE)
	@echo "Built $(APP_BUNDLE)"

install: build
	@echo "Installing to $(INSTALL_DIR)/$(APP_NAME).app (admin required: the helper runs as root, so the bundle must not be user-writable) ..."
	@sudo rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@sudo cp -R $(APP_BUNDLE) "$(INSTALL_DIR)/$(APP_NAME).app"
	@sudo chown -R root:wheel "$(INSTALL_DIR)/$(APP_NAME).app"
	@sudo chmod -R go-w "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Installed. Launch from /Applications or Spotlight."

uninstall:
	@echo "Removing $(APP_NAME)..."
	@"$(INSTALL_DIR)/$(APP_NAME).app/Contents/MacOS/$(APP_NAME)" --uninstall-helper 2>/dev/null || true
	@sudo rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@rm -f ~/Library/LaunchAgents/$(BUNDLE_ID).plist
	@sudo rm -f /etc/sudoers.d/battery /etc/sudoers.d/battery.bak
	@security delete-generic-password -s com.betterbattery.smc-hash >/dev/null 2>&1 || true
	@rm -rf ~/Library/Application\ Support/BetterBattery
	@defaults delete $(BUNDLE_ID) >/dev/null 2>&1 || true
	@echo "Uninstalled (app, daemon, LaunchAgent, sudoers, Keychain item, history, preferences)."

clean:
	@rm -rf $(BUILD_DIR)
	@echo "Cleaned."

release:
	@./scripts/release.sh

init-github:
	@./scripts/init-github.sh
