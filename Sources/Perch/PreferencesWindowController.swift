import AppKit
import Carbon.HIToolbox

// MARK: - Shortcut recorder cell

final class ShortcutCell: NSTableCellView {
    private let button = NSButton()
    private var isRecording = false
    private var currentHotkey: Hotkey?
    var onChange: ((Hotkey?) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        button.bezelStyle = .rounded
        button.translatesAutoresizingMaskIntoConstraints = false
        button.target = self
        button.action = #selector(beginRecording)
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(hotkey: Hotkey?) {
        currentHotkey = hotkey
        isRecording = false
        render()
    }

    private func render() {
        if isRecording {
            button.title = "● Press shortcut…"
            button.contentTintColor = .systemRed
        } else {
            button.title = currentHotkey?.displayString ?? "—  (click to set)"
            button.contentTintColor = currentHotkey != nil ? .labelColor : .tertiaryLabelColor
        }
    }

    @objc private func beginRecording() {
        isRecording = true
        HotkeyManager.shared.isPaused = true
        render()
        window?.makeFirstResponder(self)
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }

        if Int(event.keyCode) == kVK_Escape {
            // Escape clears the binding
            isRecording = false
            currentHotkey = nil
            HotkeyManager.shared.isPaused = false
            render()
            onChange?(nil)
            return
        }

        let nsFlags = event.modifierFlags.intersection([.control, .option, .command, .shift])
        // Require at least one modifier so bare letter keys aren't accidentally bound.
        guard !nsFlags.isEmpty else { return }

        var cgFlags: CGEventFlags = []
        if nsFlags.contains(.control) { cgFlags.insert(.maskControl) }
        if nsFlags.contains(.option)  { cgFlags.insert(.maskAlternate) }
        if nsFlags.contains(.command) { cgFlags.insert(.maskCommand) }
        if nsFlags.contains(.shift)   { cgFlags.insert(.maskShift) }

        let newHotkey = Hotkey(keyCode: Int(event.keyCode), modifierFlags: cgFlags.rawValue)
        isRecording = false
        currentHotkey = newHotkey
        HotkeyManager.shared.isPaused = false
        render()
        onChange?(newHotkey)
    }

    override func resignFirstResponder() -> Bool {
        if isRecording {
            isRecording = false
            HotkeyManager.shared.isPaused = false
            render()
        }
        return super.resignFirstResponder()
    }
}

// MARK: - Preferences window

final class PreferencesWindowController: NSWindowController,
                                         NSTableViewDataSource, NSTableViewDelegate {
    private var tableView = NSTableView()
    private var rows: [(action: SnapAction, hotkey: Hotkey?)] = []
    private var dragModifierPopup = NSPopUpButton()

    convenience init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 610),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Perch"
        win.center()
        self.init(window: win)
        buildUI()
        reloadRows()
    }

    override init(window: NSWindow?) { super.init(window: window) }
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let cv = window?.contentView else { return }

        let header = NSTextField(labelWithString: "Keyboard Shortcuts")
        header.font = .boldSystemFont(ofSize: 14)
        header.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(header)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        cv.addSubview(scroll)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 28

        let actionCol = NSTableColumn(identifier: .init("action"))
        actionCol.title = "Action"
        actionCol.width = 200
        actionCol.minWidth = 160

        let shortcutCol = NSTableColumn(identifier: .init("shortcut"))
        shortcutCol.title = "Shortcut  (Esc = clear)"
        shortcutCol.width = 200
        shortcutCol.minWidth = 160

        tableView.addTableColumn(actionCol)
        tableView.addTableColumn(shortcutCol)
        scroll.documentView = tableView

        let note = NSTextField(wrappingLabelWithString:
            "Hotkeys work globally. Click a shortcut cell and press any modifier + key combination.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(note)

        // Drag modifier section
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(sep)

        let dragHeader = NSTextField(labelWithString: "Window Drag")
        dragHeader.font = .boldSystemFont(ofSize: 13)
        dragHeader.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(dragHeader)

        let dragLabel = NSTextField(labelWithString: "Modifier key:")
        dragLabel.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(dragLabel)

        dragModifierPopup.translatesAutoresizingMaskIntoConstraints = false
        for mod in DragModifier.allCases {
            dragModifierPopup.addItem(withTitle: mod.displayName)
            dragModifierPopup.lastItem?.tag = mod.rawValue
        }
        dragModifierPopup.selectItem(withTag: Config.shared.dragModifier.rawValue)
        dragModifierPopup.target = self
        dragModifierPopup.action = #selector(dragModifierChanged)
        cv.addSubview(dragModifierPopup)

        let dragNote = NSTextField(labelWithString: "Hold modifier + click-drag anywhere on a window to move it.")
        dragNote.font = .systemFont(ofSize: 11)
        dragNote.textColor = .secondaryLabelColor
        dragNote.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(dragNote)

        let resetBtn = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetDefaults))
        resetBtn.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(resetBtn)

        // Menu bar section
        let sep2 = NSBox()
        sep2.boxType = .separator
        sep2.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(sep2)

        let menuBarHeader = NSTextField(labelWithString: "Menu Bar")
        menuBarHeader.font = .boldSystemFont(ofSize: 13)
        menuBarHeader.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(menuBarHeader)

        let showIconBtn = NSButton(title: "Show Menu Bar Icon", target: self, action: #selector(showMenuBarIcon))
        showIconBtn.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(showIconBtn)

        let menuBarNote = NSTextField(labelWithString: "Use \"Hide Menu Bar Icon\" in the menu bar to run Perch silently in the background.")
        menuBarNote.font = .systemFont(ofSize: 11)
        menuBarNote.textColor = .secondaryLabelColor
        menuBarNote.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(menuBarNote)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: cv.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: note.topAnchor, constant: -8),

            note.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            note.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),
            note.bottomAnchor.constraint(equalTo: sep.topAnchor, constant: -12),

            sep.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            sep.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),
            sep.bottomAnchor.constraint(equalTo: dragHeader.topAnchor, constant: -10),

            dragHeader.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            dragHeader.bottomAnchor.constraint(equalTo: dragModifierPopup.topAnchor, constant: -8),

            dragLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            dragLabel.centerYAnchor.constraint(equalTo: dragModifierPopup.centerYAnchor),

            dragModifierPopup.leadingAnchor.constraint(equalTo: dragLabel.trailingAnchor, constant: 8),
            dragModifierPopup.bottomAnchor.constraint(equalTo: dragNote.topAnchor, constant: -6),
            dragModifierPopup.widthAnchor.constraint(equalToConstant: 180),

            resetBtn.centerYAnchor.constraint(equalTo: dragModifierPopup.centerYAnchor),
            resetBtn.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),

            dragNote.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            dragNote.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),
            dragNote.bottomAnchor.constraint(equalTo: sep2.topAnchor, constant: -12),

            sep2.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            sep2.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),
            sep2.bottomAnchor.constraint(equalTo: menuBarHeader.topAnchor, constant: -10),

            menuBarHeader.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            menuBarHeader.bottomAnchor.constraint(equalTo: showIconBtn.topAnchor, constant: -8),

            showIconBtn.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            showIconBtn.bottomAnchor.constraint(equalTo: menuBarNote.topAnchor, constant: -6),

            menuBarNote.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            menuBarNote.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),
            menuBarNote.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -16),
        ])
    }

    private func reloadRows() {
        let bindings = Config.shared.bindings
        rows = SnapAction.allCases.map { ($0, bindings[$0]) }
        tableView.reloadData()
    }

    @objc private func dragModifierChanged() {
        let tag = dragModifierPopup.selectedTag()
        if let mod = DragModifier(rawValue: tag) {
            Config.shared.dragModifier = mod
        }
    }

    @objc private func resetDefaults() {
        Config.shared.bindings = Config.defaultBindings
        reloadRows()
    }

    @objc private func showMenuBarIcon() {
        (NSApp.delegate as? AppDelegate)?.showMenuBarIcon()
    }

    // MARK: NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    // MARK: NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = rows[row]

        if tableColumn?.identifier.rawValue == "action" {
            let id = NSUserInterfaceItemIdentifier("actionCell")
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView
                ?? NSTableCellView()
            cell.identifier = id
            if cell.textField == nil {
                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(tf)
                cell.textField = tf
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            cell.textField?.stringValue = item.action.displayName
            return cell
        } else {
            let id = NSUserInterfaceItemIdentifier("shortcutCell")
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? ShortcutCell
                ?? ShortcutCell()
            cell.identifier = id
            cell.configure(hotkey: item.hotkey)
            cell.onChange = { [weak self] newHotkey in
                guard let self else { return }
                var bindings = Config.shared.bindings
                bindings[item.action] = newHotkey
                Config.shared.bindings = bindings
                self.rows[row] = (item.action, newHotkey)
            }
            return cell
        }
    }
}
