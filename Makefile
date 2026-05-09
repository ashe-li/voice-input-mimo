APP_NAME := VoiceInputMimo
APP_BUNDLE := $(APP_NAME).app
BUILD_DIR := $(shell swift build -c release --show-bin-path 2>/dev/null || echo .build/release)

.PHONY: build clean install run server-start server-stop e2e-phase1 e2e-phase2 e2e-phase3

build:
	swift build -c release
	$(eval BUILD_DIR := $(shell swift build -c release --show-bin-path))
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	cp Info.plist $(APP_BUNDLE)/Contents/
	cp -R Resources/. $(APP_BUNDLE)/Contents/Resources/
	codesign --force --sign - $(APP_BUNDLE)
	@echo "\n✅ Built $(APP_BUNDLE)"

run: build
	open $(APP_BUNDLE)

clean:
	swift package clean
	rm -rf $(APP_BUNDLE)

install: build
	rm -rf /Applications/$(APP_BUNDLE)
	cp -r $(APP_BUNDLE) /Applications/
	@echo "✅ Installed to /Applications/$(APP_BUNDLE)"

server-start:
	cd server && MIMO_PRELOAD=1 nohup ./run.sh > /tmp/mimo-asr-server.log 2>&1 &
	@echo "→ Server starting in background. Logs: /tmp/mimo-asr-server.log"
	@echo "→ Wait until 'Application startup complete' appears (~10 min cold start)."

server-stop:
	@pkill -f 'uvicorn server:app' && echo "✅ Server stopped" || echo "ℹ️ Server not running"

# Phase E2E acceptance gates. Each phase must pass its gate before moving on.
# Phase 1 = data layer + LLMRefiner integration.
# Phase 2 = SwiftUI Hybrid foundation (Sendable + protocols + ViewModel + 5 components).
# Phase 3 = Settings AppKit form → SwiftUI panes (NavigationSplitView + 7 panes).
# Phase 4-6 gates will be added as those phases are implemented.

e2e-phase1:
	@bash scripts/e2e/phase1_gate.sh

e2e-phase2:
	@bash scripts/e2e/phase2_gate.sh

e2e-phase3:
	@bash scripts/e2e/phase3_gate.sh
