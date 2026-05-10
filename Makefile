APP_NAME := VoiceInputMimo
APP_BUNDLE := $(APP_NAME).app
BUILD_DIR := $(shell swift build -c release --show-bin-path 2>/dev/null || echo .build/release)
CODESIGN_IDENTITY ?= VoiceInputMimo Local
# Pick a signing identity. The named local cert (created by `make cert-setup`)
# yields a stable bundle hash across rebuilds, so macOS TCC remembers
# Microphone + Accessibility grants. Without it we fall back to ad-hoc `-`,
# which generates a fresh hash every build → TCC re-prompts on every install.
SIGNARG := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -qF "$(CODESIGN_IDENTITY)" && echo "$(CODESIGN_IDENTITY)" || echo "-")

.PHONY: build clean install run cert-setup dmg server-start server-stop e2e-phase1 e2e-phase2 e2e-phase3 e2e-phase4 e2e-phase5 e2e-phase6

build:
	swift build -c release
	$(eval BUILD_DIR := $(shell swift build -c release --show-bin-path))
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	cp Info.plist $(APP_BUNDLE)/Contents/
	cp -R Resources/. $(APP_BUNDLE)/Contents/Resources/
	@if [ "$(SIGNARG)" = "-" ]; then \
	  echo "⚠️  Ad-hoc signing — TCC will re-prompt on every install."; \
	  echo "   Run \`make cert-setup\` once for stable signing."; \
	fi
	codesign --force --sign "$(SIGNARG)" $(APP_BUNDLE)
	@echo "\n✅ Built $(APP_BUNDLE) (signed: $(SIGNARG))"

cert-setup:
	@bash scripts/setup-codesign-cert.sh

run: build
	open $(APP_BUNDLE)

clean:
	swift package clean
	rm -rf $(APP_BUNDLE)

install: build
	rm -rf /Applications/$(APP_BUNDLE)
	cp -r $(APP_BUNDLE) /Applications/
	@echo "✅ Installed to /Applications/$(APP_BUNDLE)"

# Build a distributable DMG (self-signed, NOT Apple-notarized). Output goes
# to dist/. Override version with `VERSION=1.2.3 make dmg`. Downloaders need
# to right-click → Open the first time to bypass Gatekeeper — see
# README-INSTALL.txt that gets bundled into the DMG.
dmg: build
	@bash scripts/build-dmg.sh

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
# Phase 4 = Prompts pane (Profiles + Skills Library + Import/Export).
# Phase 5 = ClipboardHistory SwiftUI cards (LazyVGrid + sidebar filter).
# Phase 6 = startup wiring + status menu profile switcher + overlay label.

e2e-phase1:
	@bash scripts/e2e/phase1_gate.sh

e2e-phase2:
	@bash scripts/e2e/phase2_gate.sh

e2e-phase3:
	@bash scripts/e2e/phase3_gate.sh

e2e-phase4:
	@bash scripts/e2e/phase4_gate.sh

e2e-phase5:
	@bash scripts/e2e/phase5_gate.sh

e2e-phase6:
	@bash scripts/e2e/phase6_gate.sh
