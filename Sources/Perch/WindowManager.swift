import AppKit
import CoreGraphics

final class WindowManager {
    static let shared = WindowManager()

    // The six horizontal snap zones, mirroring Windows Snap (Win+Left/Right). Deliberately
    // stateless: nothing is remembered between presses. Every press re-derives which of
    // these states the focused window is actually in from its live on-screen frame, looks
    // up the fixed transition for the key pressed, and applies it. No other window's
    // position or size is ever consulted — overlapping snapped windows is expected.
    private enum HState: CaseIterable {
        case fullScreen, leftHalf, rightHalf, leftThird, centerThird, rightThird
        case leftTwoThirds, rightTwoThirds
    }

    private enum Direction { case left, right }

    @discardableResult
    func snap(_ action: SnapAction) -> Bool {
        guard let window = focusedWindow() else { return false }
        guard let screen = screenFor(window: window) ?? NSScreen.main else { return false }

        if let direction = Self.direction(of: action) {
            // A window not currently sitting in one of the eight zones (never snapped,
            // or manually resized to something else) is treated the same as Full
            // Screen — the first press always lands on a half, same as Windows Snap.
            let current = currentState(of: window, on: screen) ?? .fullScreen

            // At the edge of a monitor — as far left/right as a Third goes — continue
            // onto the neighboring monitor if there is one, landing on the mirrored
            // third, as if the window slid off this screen's edge and reappeared on
            // the adjacent one. With no neighbor in that direction, falls through to
            // the ordinary self-loop (stays put).
            if (current == .leftThird && direction == .left) || (current == .rightThird && direction == .right),
               let neighbor = adjacentScreen(to: screen, direction: direction) {
                let mirrored: HState = direction == .left ? .rightThird : .leftThird
                // Different monitors can have different resolutions, so height changes
                // too — always resize before repositioning here (rather than the
                // width-only heuristic setFrame otherwise uses), so the window is
                // already the right height while it's still safely on the old screen,
                // instead of landing on the new one at the old height and risking
                // getting constrained to whichever screen is shorter.
                setFrame(rect(for: mirrored, in: neighbor), for: window, sizeFirst: true)
                return true
            }

            // Which third-zones another window currently occupies, checked live (not
            // tracked) so it's always correct even if another window moved, closed, or
            // was resized since the last press. This decides two things: whether Centre
            // Third or a Two Thirds span is reachable at all, and which one wins.
            let occupied = occupiedThirds(excluding: window, on: screen)
            let next = Self.transition(current, direction, occupiedThirds: occupied)
            setFrame(rect(for: next, in: screen), for: window)
            return true
        }

        // Every other hotkey (maximize, center, quarters, top/bottom half) is a fixed
        // target — it doesn't chain off whatever the window was doing before.
        setFrame(action.targetFrame(in: screen), for: window)
        return true
    }

    // Direct snap from drag — skips focusedWindow() lookup. Always a fixed target, same
    // as the keyboard path for non-directional actions.
    func applySnap(_ action: SnapAction, to window: AXUIElement, on screen: NSScreen) {
        setFrame(action.targetFrame(in: screen), for: window)
    }

    // MARK: - Transition table

    private static func direction(of action: SnapAction) -> Direction? {
        switch action {
        case .leftHalf:  return .left
        case .rightHalf: return .right
        default:         return nil
        }
    }

    // Centre Third and the Two Thirds spans only make sense as part of a multi-window
    // thirds layout — occupiedThirds is which third-zones another window currently
    // holds, and decides whether either is reachable, and which one wins:
    //   - Landing on a plain Half (from Full Screen, a crossover, or growing past a Two
    //     Thirds span) upgrades to the matching Two Thirds whenever the complementary
    //     third is occupied (Left Third occupied → Right Two Thirds tiles the rest of
    //     the screen against it, and the mirror for Right Third → Left Two Thirds).
    //   - Leaving a Third outward stops at Half first (not Two Thirds directly) so
    //     Half is always a reachable stop between a Third and its Two Thirds — pressing
    //     the grow key again from there continues toward Two Thirds as long as the
    //     complementary third is still occupied; otherwise it falls back to the
    //     ordinary crossover-to-the-other-side behavior. Failing any of that, Centre
    //     Third if any other third is occupied; failing that, plain Half.
    //   - Shrinking (the key matching the current anchor) never needs an occupancy
    //     check — it always steps straight down: Two Thirds → Half → Third.
    private static func transition(_ state: HState, _ direction: Direction, occupiedThirds: Set<HState>) -> HState {
        switch (state, direction) {
        case (.fullScreen,      .left):  return halfOrTwoThirds(.left, occupiedThirds)
        case (.fullScreen,      .right): return halfOrTwoThirds(.right, occupiedThirds)

        case (.leftHalf,        .left):  return .leftThird
        case (.leftHalf,        .right):
            if occupiedThirds.contains(.rightThird) { return .leftTwoThirds }
            return halfOrTwoThirds(.right, occupiedThirds)

        case (.rightHalf,       .left):
            if occupiedThirds.contains(.leftThird) { return .rightTwoThirds }
            return halfOrTwoThirds(.left, occupiedThirds)
        case (.rightHalf,       .right): return .rightThird

        case (.leftThird,       .left):  return .leftThird
        case (.leftThird,       .right):
            if occupiedThirds.contains(.rightThird) { return .leftHalf }
            if !occupiedThirds.isEmpty { return .centerThird }
            return .leftHalf

        // Landing directly on a Third that's already occupied by another window would
        // be a silent full overlap — stop at the adjacent Half first, same as every
        // other edge that avoids landing straight on an occupied region.
        case (.centerThird,     .left):
            return occupiedThirds.contains(.leftThird) ? .leftHalf : .leftThird
        case (.centerThird,     .right):
            return occupiedThirds.contains(.rightThird) ? .rightHalf : .rightThird

        case (.rightThird,      .left):
            if occupiedThirds.contains(.leftThird) { return .rightHalf }
            if !occupiedThirds.isEmpty { return .centerThird }
            return .rightHalf
        case (.rightThird,      .right): return .rightThird

        case (.leftTwoThirds,   .left):  return .leftHalf
        case (.leftTwoThirds,   .right): return halfOrTwoThirds(.right, occupiedThirds)

        case (.rightTwoThirds,  .left):  return halfOrTwoThirds(.left, occupiedThirds)
        case (.rightTwoThirds,  .right): return .rightHalf
        }
    }

    // The target when a transition would land on a plain Half: if the third *on the
    // same side* as that Half is occupied, ANY target starting there (Half or Two
    // Thirds) would overlap it, so Centre Third wins outright — checked first,
    // regardless of what else is occupied. Only once that's ruled out does the
    // complementary third get a say: occupied, it upgrades to the matching Two Thirds
    // span (they tile together against it); otherwise, the plain Half.
    private static func halfOrTwoThirds(_ direction: Direction, _ occupiedThirds: Set<HState>) -> HState {
        switch direction {
        case .left:
            if occupiedThirds.contains(.leftThird)  { return .centerThird }
            if occupiedThirds.contains(.rightThird) { return .leftTwoThirds }
            return .leftHalf
        case .right:
            if occupiedThirds.contains(.rightThird) { return .centerThird }
            if occupiedThirds.contains(.leftThird)  { return .rightTwoThirds }
            return .rightHalf
        }
    }

    // MARK: - State <-> geometry

    private func rect(for state: HState, in screen: NSScreen) -> NSRect {
        let f = screen.visibleFrame
        switch state {
        case .fullScreen:
            return f
        case .leftHalf:
            return NSRect(x: f.minX, y: f.minY, width: f.width / 2, height: f.height)
        case .rightHalf:
            return NSRect(x: f.midX, y: f.minY, width: f.width / 2, height: f.height)
        case .leftThird:
            return NSRect(x: f.minX, y: f.minY, width: f.width / 3, height: f.height)
        case .centerThird:
            return NSRect(x: f.minX + f.width / 3, y: f.minY, width: f.width / 3, height: f.height)
        case .rightThird:
            return NSRect(x: f.minX + 2 * f.width / 3, y: f.minY, width: f.width / 3, height: f.height)
        case .leftTwoThirds:
            return NSRect(x: f.minX, y: f.minY, width: f.width * 2 / 3, height: f.height)
        case .rightTwoThirds:
            return NSRect(x: f.minX + f.width / 3, y: f.minY, width: f.width * 2 / 3, height: f.height)
        }
    }

    private func currentState(of window: AXUIElement, on screen: NSScreen) -> HState? {
        guard let frame = currentAppKitFrame(of: window) else { return nil }
        return HState.allCases.first { Self.framesMatch(frame, rect(for: $0, in: screen)) }
    }

    // Apps often can't take an exact frame (grid-snapping terminals, minimum window
    // sizes), so matching against a candidate zone allows a small tolerance.
    private static func framesMatch(_ a: NSRect, _ b: NSRect, tolerance: CGFloat = 10) -> Bool {
        abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
            && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }

    // Which of Left/Centre/Right Third another window — from any app, checked live
    // rather than tracked — currently occupies on this screen. A single CGWindowList
    // query covers every on-screen window in one shot, rather than walking each running
    // app's AX tree (which would mean a blocking IPC round-trip per app on every press).
    private func occupiedThirds(excluding window: AXUIElement, on screen: NSScreen) -> Set<HState> {
        guard let excludeFrame = currentAppKitFrame(of: window),
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        let candidates: [HState] = [.leftThird, .centerThird, .rightThird]
        let candidateRects = candidates.map { ($0, rect(for: $0, in: screen)) }
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let ownPID = ProcessInfo.processInfo.processIdentifier

        var result = Set<HState>()
        for entry in list {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let ownerPID = entry[kCGWindowOwnerPID as String] as? Int, pid_t(ownerPID) != ownPID,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = boundsDict["X"], let y = boundsDict["Y"],
                  let w = boundsDict["Width"], let h = boundsDict["Height"]
            else { continue }

            let appKitFrame = NSRect(x: x, y: primaryH - (y + h), width: w, height: h)
            if Self.framesMatch(appKitFrame, excludeFrame) { continue }  // this is `window` itself
            for (state, rect) in candidateRects where Self.framesMatch(appKitFrame, rect) {
                result.insert(state)
            }
        }
        return result
    }

    // MARK: - AX / geometry plumbing

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

    private func currentAppKitFrame(of window: AXUIElement) -> NSRect? {
        guard let qf = quartzFrame(of: window) else { return nil }
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: qf.minX, y: primaryH - qf.maxY, width: qf.width, height: qf.height)
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

    // The nearest other monitor positioned immediately to the left/right of this one
    // (by AppKit global frame, which already reflects the System Settings › Displays
    // arrangement), or nil if there isn't one in that direction.
    private func adjacentScreen(to screen: NSScreen, direction: Direction) -> NSScreen? {
        let tolerance: CGFloat = 2
        let others = NSScreen.screens.filter { $0 !== screen }
        switch direction {
        case .left:
            return others
                .filter { $0.frame.maxX <= screen.frame.minX + tolerance }
                .max { $0.frame.maxX < $1.frame.maxX }
        case .right:
            return others
                .filter { $0.frame.minX >= screen.frame.maxX - tolerance }
                .min { $0.frame.minX < $1.frame.minX }
        }
    }

    // Accepts an AppKit-coordinate rect and applies it via AXUIElement (Quartz coords).
    // sizeFirst overrides the automatic order detection below — pass true when the
    // move crosses screens of different resolutions, where a width-only comparison
    // isn't enough to pick the safe order (see the cross-monitor call site).
    private func setFrame(_ appKitFrame: NSRect, for window: AXUIElement, sizeFirst: Bool? = nil) {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        var pos = CGPoint(x: appKitFrame.minX, y: primaryH - appKitFrame.maxY)
        var size = CGSize(width: appKitFrame.width, height: appKitFrame.height)

        guard let posVal  = AXValueCreate(.cgPoint, &pos),
              let sizeVal = AXValueCreate(.cgSize,  &size)
        else { return }

        // Position and size are two separate, instantly-applied AX calls, so for an
        // instant the window sits at a mismatched combination of old/new position and
        // size — which can briefly uncover whatever's underneath. Order picks the side
        // that avoids that: growing sets size first (still at the old position, so the
        // intermediate rect only ever extends past — never shrinks below — what was
        // already covered); shrinking sets position first (still at the old size, so
        // the intermediate rect fully covers the destination before shrinking into it).
        let isGrowing = sizeFirst ?? ((currentAppKitFrame(of: window)?.width ?? 0) < appKitFrame.width)
        if isGrowing {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeVal)
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posVal)
        } else {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posVal)
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeVal)
        }

        // Some apps silently drop one of the two attribute writes above instead of
        // applying both — the window is then stuck in a hybrid of the old and new
        // geometry (e.g. the new position but the old size). Verify the result and, if
        // it didn't fully take, retry once with the opposite order in case the app
        // rejected that specific ordering rather than the values themselves.
        if let result = currentAppKitFrame(of: window), !Self.framesMatch(result, appKitFrame) {
            if isGrowing {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posVal)
                AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeVal)
            } else {
                AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeVal)
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posVal)
            }
        }

        // Moving a window so it now overlaps another can cause the OS to reconsider key
        // status as a side effect of the resize on some apps — reassert that this window
        // (and its owning app) stays focused, so the snap never silently hands focus to
        // whatever it's now sitting on top of.
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        var pid: pid_t = 0
        if AXUIElementGetPid(window, &pid) == .success {
            NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        }
    }
}

extension CGRect {
    var area: CGFloat { width * height }
}
