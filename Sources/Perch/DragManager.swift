import AppKit
import CoreGraphics

final class DragManager {
    static let shared = DragManager()

    private var dragWindow: AXUIElement?
    private var windowOriginAtStart = CGPoint.zero
    private var mouseAtStart = CGPoint.zero
    private var isTracking = false
    private var isCommitted = false
    private var pendingSnapAction: SnapAction? = nil

    private let dragThreshold: CGFloat = 10
    private let snapActivationDistance: CGFloat = 30

    // True while a committed drag is in progress — used to suppress hotkeys mid-drag.
    var isActiveDrag: Bool { isCommitted }

    func mouseDown(at point: CGPoint, flags: CGEventFlags, isRightButton: Bool) -> Bool {
        reset()

        let required = Config.shared.dragModifier.flags
        guard flags.contains(required) else { return false }

        guard let window = axWindow(at: point),
              let origin = quartzPosition(of: window)
        else { return isRightButton }

        dragWindow = window
        windowOriginAtStart = origin
        mouseAtStart = point
        isTracking = true

        // Always consume the mouseDown so the system's parallel drag gesture (e.g.
        // Command+leftMouseDown = "move background window without focusing") never starts.
        // If both start but we eat all mouseDragged/mouseUp events, the system gesture is
        // stuck without a mouseUp and moves the window on subsequent cursor movements.
        return true
    }

    func mouseDragged(at point: CGPoint) -> Bool {
        guard isTracking, let window = dragWindow else { return false }

        if !isCommitted {
            let ddx = point.x - mouseAtStart.x
            let ddy = point.y - mouseAtStart.y
            guard hypot(ddx, ddy) >= dragThreshold else { return false }
            isCommitted = true
        }

        let dx = point.x - mouseAtStart.x
        let dy = point.y - mouseAtStart.y
        setQuartzPosition(
            CGPoint(x: windowOriginAtStart.x + dx, y: windowOriginAtStart.y + dy),
            for: window
        )

        let modifierHeld = CGEventSource.flagsState(.combinedSessionState)
            .contains(Config.shared.dragModifier.flags)

        // Determine which snap zone applies: zone-based when modifier held,
        // edge-based (cursor must reach the screen edge) when modifier released.
        let zoneAction: SnapAction?
        if modifierHeld {
            let totalMoved = hypot(point.x - mouseAtStart.x, point.y - mouseAtStart.y)
            zoneAction = totalMoved >= snapActivationDistance ? snapZone(forQuartzCursor: point) : nil
        } else {
            zoneAction = edgeSnapZone(forQuartzCursor: point)
        }

        if let action = zoneAction, let screen = screenForQuartzPoint(point) {
            pendingSnapAction = action
            SnapPreviewWindow.shared.show(appKitFrame: action.targetFrame(in: screen))
        } else {
            pendingSnapAction = nil
            SnapPreviewWindow.shared.hide()
        }

        return true
    }

    @discardableResult
    func mouseUp(at point: CGPoint) -> Bool {
        let wasTracking = isTracking
        let wasCommitted = isCommitted
        let capturedWindow = dragWindow
        let capturedSnap = pendingSnapAction

        reset()
        SnapPreviewWindow.shared.hide()

        if wasCommitted,
           let action = capturedSnap,
           let window = capturedWindow,
           let screen = screenForQuartzPoint(point) {
            WindowManager.shared.applySnap(action, to: window, on: screen)
        }

        // Symmetric with mouseDown: we consumed the mouseDown when tracking started,
        // so always consume the matching mouseUp. This prevents an orphaned mouse-release
        // event from reaching the system or apps and confusing their input state.
        return wasTracking
    }

    // MARK: - Private

    private func reset() {
        isTracking = false
        isCommitted = false
        dragWindow = nil
        pendingSnapAction = nil
    }

    // Height of the primary screen — the anchor for Quartz↔AppKit Y-axis conversion.
    private var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    // 3×3 grid — just be in the right zone, no need to go to the screen edge.
    //
    //  ┌──────────┬────────────┬──────────┐
    //  │ top-left │  maximize  │ top-right│  row 0: top third
    //  ├──────────┼────────────┼──────────┤
    //  │   left   │  (nothing) │  right   │  row 1: middle third
    //  ├──────────┼────────────┼──────────┤
    //  │ bot-left │  (nothing) │ bot-right│  row 2: bottom third
    //  └──────────┴────────────┴──────────┘
    //    col 0        col 1       col 2
    //
    private func snapZone(forQuartzCursor cursor: CGPoint) -> SnapAction? {
        guard let screen = screenForQuartzPoint(cursor) else { return nil }

        let f = screen.frame
        let relX = (cursor.x - f.minX) / f.width
        let screenTopQ = primaryScreenHeight - (f.minY + f.height)
        let relY = (cursor.y - screenTopQ) / f.height

        let col = relX < 1.0/3.0 ? 0 : (relX > 2.0/3.0 ? 2 : 1)
        let row = relY < 1.0/3.0 ? 0 : (relY > 2.0/3.0 ? 2 : 1)

        switch (col, row) {
        case (0, 0): return .topLeftQuarter
        case (0, 1): return .leftHalf
        case (0, 2): return .bottomLeftQuarter
        case (1, 0): return .maximize
        case (2, 0): return .topRightQuarter
        case (2, 1): return .rightHalf
        case (2, 2): return .bottomRightQuarter
        default:     return nil
        }
    }

    // Edge-based snapping used when the modifier is released mid-drag.
    // Cursor must be within edgePx of the screen edge, matching native macOS tiling feel.
    private func edgeSnapZone(forQuartzCursor cursor: CGPoint) -> SnapAction? {
        guard let screen = screenForQuartzPoint(cursor) else { return nil }

        let f = screen.frame
        let screenTopQ = primaryScreenHeight - (f.minY + f.height)

        let edgePx: CGFloat = 5
        let nearLeft   = cursor.x <= f.minX + edgePx
        let nearRight  = cursor.x >= f.maxX - edgePx
        let nearTop    = cursor.y <= screenTopQ + edgePx
        let nearBottom = cursor.y >= screenTopQ + f.height - edgePx

        if nearLeft  && nearTop    { return .topLeftQuarter }
        if nearRight && nearTop    { return .topRightQuarter }
        if nearLeft  && nearBottom { return .bottomLeftQuarter }
        if nearRight && nearBottom { return .bottomRightQuarter }
        if nearLeft                { return .leftHalf }
        if nearRight               { return .rightHalf }
        if nearTop                 { return .maximize }
        return nil
    }

    private func screenForQuartzPoint(_ point: CGPoint) -> NSScreen? {
        let primaryH = primaryScreenHeight
        return NSScreen.screens.first { screen in
            let f = screen.frame
            let qTop    = primaryH - (f.minY + f.height)
            let qBottom = primaryH - f.minY
            return point.x >= f.minX && point.x <= f.maxX
                && point.y >= qTop   && point.y <= qBottom
        }
    }

    // MARK: - AX helpers (Quartz / top-left-origin coordinates)

    private func axWindow(at point: CGPoint) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success,
              let element
        else { return nil }
        return walkToWindow(element)
    }

    private func walkToWindow(_ element: AXUIElement) -> AXUIElement? {
        var current = element
        for _ in 0..<30 {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &roleRef)
            if (roleRef as? String) == kAXWindowRole { return current }

            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parent = parentRef,
                  CFGetTypeID(parent) == AXUIElementGetTypeID()
            else { return nil }
            current = parent as! AXUIElement
        }
        return nil
    }

    private func quartzPosition(of window: AXUIElement) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &ref) == .success,
              let val = ref,
              CFGetTypeID(val) == AXValueGetTypeID()
        else { return nil }
        var pt = CGPoint.zero
        AXValueGetValue(val as! AXValue, .cgPoint, &pt)
        return pt
    }

    private func setQuartzPosition(_ point: CGPoint, for window: AXUIElement) {
        var pt = point
        guard let val = AXValueCreate(.cgPoint, &pt) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, val)
    }
}
