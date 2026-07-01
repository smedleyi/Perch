import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var prefsController: PreferencesWindowController?
    private var quitShortcutMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        promptForAccessibilityIfNeeded()
        HotkeyManager.shared.start()
        if !Config.shared.menuBarIconHidden {
            setupMenuBar()
            updateMenuBarStatus()
        }
        installQuitShortcut()
    }

    // Clicking the Dock icon (visible when menu bar icon is hidden) reopens Preferences.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
        -> Bool
    {
        openPreferences()
        return true
    }

    // MARK: - Menu bar icon visibility

    func showMenuBarIcon() {
        guard statusItem == nil else { return }
        Config.shared.menuBarIconHidden = false
        setupMenuBar()
        updateMenuBarStatus()
    }

    func hideMenuBarIcon() {
        Config.shared.menuBarIconHidden = true
        statusItem = nil  // removes item from the menu bar; app stays invisible (.accessory)
    }

    // MARK: - Private

    // .accessory apps have no app menu bar, so Cmd+Q isn't wired up by the
    // system. Catch it ourselves whenever one of our windows (e.g. Preferences) is key.
    // The returned monitor must be retained — otherwise ARC releases it immediately
    // and the shortcut silently stops working.
    private func installQuitShortcut() {
        quitShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "q" {
                NSApp.terminate(nil)
                return nil
            }
            return event
        }
    }

    private func promptForAccessibilityIfNeeded() {
        let opts =
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        guard !AXIsProcessTrustedWithOptions(opts) else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let alert = NSAlert()
            alert.messageText = "Accessibility Access Required"
            alert.informativeText = """
                Perch needs Accessibility access to move windows and capture global hotkeys.

                Go to System Settings › Privacy & Security › Accessibility, \
                enable Perch, then relaunch.

                If Perch already appears in the list, remove it, then relaunch \
                to add it fresh.
                """
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(
                    URL(
                        string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                    )!
                )
            }
        }
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let menu = NSMenu()

        let prefsItem = NSMenuItem(
            title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        let hideItem = NSMenuItem(
            title: "Hide Menu Bar Icon", action: #selector(hideMenuBarIconAction), keyEquivalent: ""
        )
        hideItem.target = self
        menu.addItem(hideItem)

        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: "Quit Perch", action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    private func updateMenuBarStatus() {
        if HotkeyManager.shared.isRunning {
            statusItem?.button?.image = NSImage(
                systemSymbolName: "rectangle.split.2x2",
                accessibilityDescription: "Perch — Active"
            )
            statusItem?.button?.image?.isTemplate = true
        } else {
            statusItem?.button?.image = NSImage(
                systemSymbolName: "exclamationmark.triangle",
                accessibilityDescription: "Perch — Accessibility not granted"
            )
            statusItem?.button?.image?.isTemplate = true
        }
    }

    @objc private func hideMenuBarIconAction() {
        hideMenuBarIcon()
    }

    @objc func openPreferences() {
        if prefsController == nil {
            prefsController = PreferencesWindowController()
        }
        prefsController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
