.PHONY: run dump screenshot app install clean

# Debug build and run straight from the terminal (Ctrl-C to quit).
run:
	swift run CursorUsage

# Print the raw cursor.com payloads (usage-summary + first 25 events) to stdout
# and ~/Library/Logs/CursorUsage/. Use this to check the lane discriminator.
dump:
	swift run CursorUsage --dump

# Render the popover to docs/popover-{light,dark}.png for the README. Uses the
# built-in sample data, never your real Cursor account.
screenshot:
	swift run CursorUsage --screenshot docs

# Release build wrapped in CursorUsage.app
app:
	bash Scripts/package_app.sh

install: app
	pkill -x CursorUsage || true
	rm -rf /Applications/CursorUsage.app
	cp -r CursorUsage.app /Applications/
	open /Applications/CursorUsage.app

# Launch at login is handled by the app itself: the first launch from
# /Applications registers it as a Login Item (System Settings → General →
# Login Items & Extensions). Toggle it there or in the popover.

clean:
	rm -rf .build CursorUsage.app
