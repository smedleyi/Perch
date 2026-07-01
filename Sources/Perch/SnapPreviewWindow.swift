import AppKit

final class SnapPreviewWindow: NSWindow {
    static let shared = SnapPreviewWindow()

    private init() {
        super.init(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        contentView = SnapPreviewView()
    }

    func show(appKitFrame: NSRect) {
        if frame != appKitFrame { setFrame(appKitFrame, display: false) }
        if !isVisible { orderFront(nil) }
    }

    func hide() {
        guard isVisible else { return }
        orderOut(nil)
    }
}

private final class SnapPreviewView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // White fill in dark mode, black fill in light mode — matches native macOS snap preview
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.03).cgColor
            layer?.borderColor     = NSColor.labelColor.withAlphaComponent(0.40).cgColor
        }
        layer?.borderWidth = 3
    }
}
