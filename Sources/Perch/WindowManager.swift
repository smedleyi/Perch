import AppKit

final class WindowManager {
    static let shared = WindowManager()

    // Track the last snap so chained presses refine the position (Windows 11-style).
    private var lastWindow: AXUIElement?
    private var lastAction: SnapAction?

    @discardableResult
    func snap(_ action: SnapAction) -> Bool {
        guard let window = focusedWindow() else { return false }
        guard let screen = screenFor(window: window) ?? NSScreen.main else { return false }

        let effective: SnapAction
        if let prev = lastWindow, let prevAction = lastAction, CFEqual(prev, window) {
            effective = Self.chain(from: prevAction, input: action)
        } else {
            effective = action
        }

        setFrame(effective.targetFrame(in: screen), for: window)
        lastWindow = window
        lastAction = effective
        return true
    }

    // Maps (current snap, new key press) → refined action.
    private static func chain(from current: SnapAction, input: SnapAction) -> SnapAction {
        switch (current, input) {
        case (.leftHalf,          .maximize): return .topLeftQuarter
        case (.leftHalf,          .center):   return .bottomLeftQuarter
        case (.rightHalf,         .maximize): return .topRightQuarter
        case (.rightHalf,         .center):   return .bottomRightQuarter
        case (.topLeftQuarter,    .rightHalf):return .topRightQuarter
        case (.topLeftQuarter,    .center):   return .leftHalf
        case (.topRightQuarter,   .leftHalf): return .topLeftQuarter
        case (.topRightQuarter,   .center):   return .rightHalf
        case (.bottomLeftQuarter, .rightHalf):return .bottomRightQuarter
        case (.bottomLeftQuarter, .maximize): return .leftHalf
        case (.bottomRightQuarter,.leftHalf): return .bottomLeftQuarter
        case (.bottomRightQuarter,.maximize): return .rightHalf
        default: return input
        }
    }

    // MARK: - Private

    // Direct snap from drag — skips focusedWindow() lookup and the keyboard chain state machine.
    // Updates lastWindow/lastAction so subsequent keyboard snaps can chain from here.
    func applySnap(_ action: SnapAction, to window: AXUIElement, on screen: NSScreen) {
        setFrame(action.targetFrame(in: screen), for: window)
        lastWindow = window
        lastAction = action
    }

    private func focusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID()
        else { return nil }
        return (ref as! AXUIElement)
    }

    // Returns the window's frame in Quartz coordinates (top-left origin).
    private func quartzFrame(of window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, CFGetTypeID(posRef) == AXValueGetTypeID(),
              let sizeRef, CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }

        var pos = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        else { return nil }

        return CGRect(origin: pos, size: size)
    }

    private func screenFor(window: AXUIElement) -> NSScreen? {
        guard let qf = quartzFrame(of: window) else { return nil }
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        // Convert Quartz rect to AppKit rect for screen intersection
        let appKitFrame = NSRect(x: qf.minX, y: primaryH - qf.maxY, width: qf.width, height: qf.height)
        return NSScreen.screens.max {
            $0.frame.intersection(appKitFrame).area < $1.frame.intersection(appKitFrame).area
        }
    }

    // Accepts an AppKit-coordinate rect and applies it via AXUIElement (Quartz coords).
    private func setFrame(_ appKitFrame: NSRect, for window: AXUIElement) {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        var pos = CGPoint(x: appKitFrame.minX, y: primaryH - appKitFrame.maxY)
        var size = CGSize(width: appKitFrame.width, height: appKitFrame.height)

        guard let posVal  = AXValueCreate(.cgPoint, &pos),
              let sizeVal = AXValueCreate(.cgSize,  &size)
        else { return }

        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posVal)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeVal)
    }
}

extension CGRect {
    var area: CGFloat { width * height }
}
