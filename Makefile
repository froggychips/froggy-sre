.PHONY: build release test install uninstall status logs

BINARY       = froggy-sre
INSTALL_PATH = /usr/local/bin/$(BINARY)
PLIST_SRC    = LaunchAgent/com.froggychips.froggy-sre.plist
PLIST_DST    = $(HOME)/Library/LaunchAgents/com.froggychips.froggy-sre.plist
LABEL        = com.froggychips.froggy-sre

build:
	swift build

release:
	swift build -c release

test:
	swift test

install: release
	install -m 755 .build/release/$(BINARY) $(INSTALL_PATH)
	cp $(PLIST_SRC) $(PLIST_DST)
	launchctl load $(PLIST_DST)
	@echo "$(BINARY) installed → $(INSTALL_PATH)"
	@echo "daemon loaded     → $(LABEL)"

uninstall:
	-launchctl unload $(PLIST_DST) 2>/dev/null
	-rm -f $(PLIST_DST)
	-rm -f $(INSTALL_PATH)
	@echo "$(BINARY) uninstalled"

status:
	@launchctl list | grep $(LABEL) || echo "not running"

logs:
	tail -f /tmp/froggy-sre.log
