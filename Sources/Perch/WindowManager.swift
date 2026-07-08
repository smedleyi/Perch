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

    // The same eight-zone machine, mirrored onto the vertical axis for Top/Bottom Half
    // (⌃⌥T / ⌃⌥B). Kept as a separate enum/table rather than unifying with HState so the
    // already-validated horizontal logic above is never touched by this addition — see
    // vTransition(_:_:occupiedThirds:) for the mechanical left→top, right→bottom mapping.
    private enum VState: CaseIterable {
        case fullScreen, topHalf, bottomHalf, topThird, middleThird, bottomThird
        case topTwoThirds, bottomTwoThirds
    }

    private enum VDirection { case up, down }

    @discardableResult
    func snap(_ action: SnapAction) -> Bool {
        guard let window = focusedWindow() else { return false }
        guard let screen = screenFor(window: window) ?? NSScreen.main else { return false }

        // Combo presses: a half refined by Maximize/Center becomes the matching
        // quarter, a quarter refined by the opposite-side half hotkey moves laterally
        // to the matching quarter, and a quarter refined by whichever of Maximize/
        // Center it ISN'T already using collapses back to a half. Checked directly
        // against live geometry, same as everything else here — nothing about the
        // previous press is remembered.
        if let combo = quarterCombo(action, window: window, screen: screen) {
            setFrame(combo.targetFrame(in: screen), for: window, on: screen)
            return true
        }

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
                // area-growth heuristic setFrame otherwise uses), so the window is
                // already the right size while it's still safely on the old screen,
                // instead of landing on the new one at the old size and risking
                // getting constrained to whichever screen is smaller.
                setFrame(rect(for: mirrored, in: neighbor), for: window, on: neighbor, sizeFirst: true)
                return true
            }

            // Which third-zones another window currently occupies, checked live (not
            // tracked) so it's always correct even if another window moved, closed, or
            // was resized since the last press. This decides two things: whether Centre
            // Third or a Two Thirds span is reachable at all, and which one wins.
            let occupied = occupiedThirds(excluding: window, on: screen)
            let next = Self.transition(current, direction, occupiedThirds: occupied)
            setFrame(rect(for: next, in: screen), for: window, on: screen)
            return true
        }

        if let vDirection = Self.vDirection(of: action) {
            let current = vCurrentState(of: window, on: screen) ?? .fullScreen

            if (current == .topThird && vDirection == .up) || (current == .bottomThird && vDirection == .down),
               let neighbor = vAdjacentScreen(to: screen, direction: vDirection) {
                let mirrored: VState = vDirection == .up ? .bottomThird : .topThird
                setFrame(vRect(for: mirrored, in: neighbor), for: window, on: neighbor, sizeFirst: true)
                return true
            }

            let occupied = vOccupiedThirds(excluding: window, on: screen)
            let next = Self.vTransition(current, vDirection, occupiedThirds: occupied)
            setFrame(vRect(for: next, in: screen), for: window, on: screen)
            return true
        }

        // Every other hotkey (maximize, center, quarters) is a fixed target — it
        // doesn't chain off whatever the window was doing before.
        setFrame(action.targetFrame(in: screen), for: window, on: screen)
        return true
    }

    // Direct snap from drag — skips focusedWindow() lookup. Always a fixed target, same
    // as the keyboard path for non-directional actions.
    func applySnap(_ action: SnapAction, to window: AXUIElement, on screen: NSScreen) {
        setFrame(action.targetFrame(in: screen), for: window, on: screen)
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

    // MARK: - Vertical transition table (mechanical mirror of the one above: left→top,
    // right→bottom). See the comments on transition(_:_:occupiedThirds:) and
    // halfOrTwoThirds(_:_:) for the reasoning — identical here, just on the other axis.

    private static func vDirection(of action: SnapAction) -> VDirection? {
        switch action {
        case .topHalf:    return .up
        case .bottomHalf: return .down
        default:          return nil
        }
    }

    private static func vTransition(_ state: VState, _ direction: VDirection, occupiedThirds: Set<VState>) -> VState {
        switch (state, direction) {
        case (.fullScreen,      .up):   return vHalfOrTwoThirds(.up, occupiedThirds)
        case (.fullScreen,      .down): return vHalfOrTwoThirds(.down, occupiedThirds)

        case (.topHalf,         .up):   return .topThird
        case (.topHalf,         .down):
            if occupiedThirds.contains(.bottomThird) { return .topTwoThirds }
            return vHalfOrTwoThirds(.down, occupiedThirds)

        case (.bottomHalf,      .up):
            if occupiedThirds.contains(.topThird) { return .bottomTwoThirds }
            return vHalfOrTwoThirds(.up, occupiedThirds)
        case (.bottomHalf,      .down): return .bottomThird

        case (.topThird,        .up):   return .topThird
        case (.topThird,        .down):
            if occupiedThirds.contains(.bottomThird) { return .topHalf }
            if !occupiedThirds.isEmpty { return .middleThird }
            return .topHalf

        case (.middleThird,     .up):
            return occupiedThirds.contains(.topThird) ? .topHalf : .topThird
        case (.middleThird,     .down):
            return occupiedThirds.contains(.bottomThird) ? .bottomHalf : .bottomThird

        case (.bottomThird,     .up):
            if occupiedThirds.contains(.topThird) { return .bottomHalf }
            if !occupiedThirds.isEmpty { return .middleThird }
            return .bottomHalf
        case (.bottomThird,     .down): return .bottomThird

        case (.topTwoThirds,    .up):   return .topHalf
        case (.topTwoThirds,    .down): return vHalfOrTwoThirds(.down, occupiedThirds)

        case (.bottomTwoThirds, .up):   return vHalfOrTwoThirds(.up, occupiedThirds)
        case (.bottomTwoThirds, .down): return .bottomHalf
        }
    }

    private static func vHalfOrTwoThirds(_ direction: VDirection, _ occupiedThirds: Set<VState>) -> VState {
        switch direction {
        case .up:
            if occupiedThirds.contains(.topThird)    { return .middleThird }
            if occupiedThirds.contains(.bottomThird) { return .topTwoThirds }
            return .topHalf
        case .down:
            if occupiedThirds.contains(.bottomThird) { return .middleThird }
            if occupiedThirds.contains(.topThird)    { return .bottomTwoThirds }
            return .bottomHalf
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
        // Width is the axis that shrinks across this family (Half → Third); height is
        // always meant to be full-span, so it stays exact.
        return Self.closestZoneMatch(
            frame, HState.allCases.map { ($0, rect(for: $0, in: screen)) },
            looseWidth: true, looseHeight: false)
    }

    private static let quarters: [SnapAction] = [
        .topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter,
    ]

    private func currentQuarter(of window: AXUIElement, on screen: NSScreen) -> SnapAction? {
        guard let frame = currentAppKitFrame(of: window) else { return nil }
        // A window that's an EXACT match for some full-span state (a plain Half/Third/
        // etc on either axis) can never actually be a quarter — quarters are always
        // half-span on BOTH axes. Ruling this out first prevents the loosened,
        // single-axis-tolerant quarter search below from mistaking a genuine Half for a
        // "clamped" quarter that happens to share its position and one axis — e.g. Top
        // Half exactly matches Top Left Quarter's height and position, differing only
        // in width, which quarters loosen; with no competing quarter candidate to lose
        // the closest-fit tie-break to, that lone false match would otherwise be
        // accepted outright.
        let isExactFullSpan =
            HState.allCases.contains { Self.framesMatch(frame, rect(for: $0, in: screen)) }
            || VState.allCases.contains { Self.framesMatch(frame, vRect(for: $0, in: screen)) }
        guard !isExactFullSpan else { return nil }
        // Both axes are already half-span for a quarter, so either can be the one an
        // app's minimum size clamps taller/wider.
        return Self.closestZoneMatch(
            frame, Self.quarters.map { ($0, $0.targetFrame(in: screen)) },
            looseWidth: true, looseHeight: true)
    }

    // Whether the window is currently anchored to the left or right side at all —
    // Half, Third, or Two Thirds — not just exactly Half. The horizontal system is a
    // whole cycling state machine now (unlike the old one-shot Left/Right), so a Left
    // press doesn't always land exactly on Left Half; the combo below needs to fire
    // from anywhere in that cycle, not just that one specific stage.
    private func currentHorizontalAnchor(of window: AXUIElement, on screen: NSScreen) -> Direction? {
        switch currentState(of: window, on: screen) {
        case .leftHalf, .leftThird, .leftTwoThirds:   return .left
        case .rightHalf, .rightThird, .rightTwoThirds: return .right
        default: return nil
        }
    }

    // See the call site in snap(_:) for what each combo restores.
    private func quarterCombo(_ action: SnapAction, window: AXUIElement, screen: NSScreen) -> SnapAction? {
        switch action {
        case .maximize:
            switch currentHorizontalAnchor(of: window, on: screen) {
            case .left:  return .topLeftQuarter
            case .right: return .topRightQuarter
            case nil: break
            }
            // Vertically anchored but not yet at the Half stage (Top/Bottom Third or Two
            // Thirds) — collapse to the matching Half first rather than jumping straight
            // to Full Screen. Once already at Top/Bottom Half, this doesn't match, so a
            // second Maximize press falls through to the plain fixed-target Full Screen
            // below, same as everywhere else with no anchor.
            switch vCurrentState(of: window, on: screen) {
            case .topThird, .topTwoThirds:       return .topHalf
            case .bottomThird, .bottomTwoThirds: return .bottomHalf
            default: break
            }
            switch currentQuarter(of: window, on: screen) {
            case .bottomLeftQuarter:  return .leftHalf
            case .bottomRightQuarter: return .rightHalf
            default: return nil
            }
        case .center:
            switch currentHorizontalAnchor(of: window, on: screen) {
            case .left:  return .bottomLeftQuarter
            case .right: return .bottomRightQuarter
            case nil: break
            }
            switch currentQuarter(of: window, on: screen) {
            case .topLeftQuarter:  return .leftHalf
            case .topRightQuarter: return .rightHalf
            default: return nil
            }
        case .leftHalf:
            switch currentQuarter(of: window, on: screen) {
            case .topRightQuarter:    return .topLeftQuarter
            case .bottomRightQuarter: return .bottomLeftQuarter
            default: return nil
            }
        case .rightHalf:
            switch currentQuarter(of: window, on: screen) {
            case .topLeftQuarter:    return .topRightQuarter
            case .bottomLeftQuarter: return .bottomRightQuarter
            default: return nil
            }
        default:
            return nil
        }
    }

    private func vRect(for state: VState, in screen: NSScreen) -> NSRect {
        let f = screen.visibleFrame
        switch state {
        case .fullScreen:
            return f
        case .topHalf:
            return NSRect(x: f.minX, y: f.midY, width: f.width, height: f.height / 2)
        case .bottomHalf:
            return NSRect(x: f.minX, y: f.minY, width: f.width, height: f.height / 2)
        case .topThird:
            return NSRect(x: f.minX, y: f.minY + 2 * f.height / 3, width: f.width, height: f.height / 3)
        case .middleThird:
            return NSRect(x: f.minX, y: f.minY + f.height / 3, width: f.width, height: f.height / 3)
        case .bottomThird:
            return NSRect(x: f.minX, y: f.minY, width: f.width, height: f.height / 3)
        case .topTwoThirds:
            return NSRect(x: f.minX, y: f.minY + f.height / 3, width: f.width, height: f.height * 2 / 3)
        case .bottomTwoThirds:
            return NSRect(x: f.minX, y: f.minY, width: f.width, height: f.height * 2 / 3)
        }
    }

    private func vCurrentState(of window: AXUIElement, on screen: NSScreen) -> VState? {
        guard let frame = currentAppKitFrame(of: window) else { return nil }
        // Mirror of currentState: height is the shrinking axis here, width stays exact.
        return Self.closestZoneMatch(
            frame, VState.allCases.map { ($0, vRect(for: $0, in: screen)) },
            looseWidth: false, looseHeight: true)
    }

    // Apps often can't take an exact frame (grid-snapping terminals, minimum window
    // sizes), so matching against a candidate zone allows a small tolerance.
    private static func framesMatch(_ a: NSRect, _ b: NSRect, tolerance: CGFloat = 10) -> Bool {
        abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
            && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }

    private static func zoneMatch(
        _ actual: NSRect, _ candidate: NSRect, looseWidth: Bool, looseHeight: Bool, tolerance: CGFloat = 10
    ) -> Bool {
        guard abs(actual.minX - candidate.minX) < tolerance, abs(actual.minY - candidate.minY) < tolerance
        else { return false }
        let widthOK =
            looseWidth
            ? actual.width >= candidate.width - tolerance
            : abs(actual.width - candidate.width) < tolerance
        let heightOK =
            looseHeight
            ? actual.height >= candidate.height - tolerance
            : abs(actual.height - candidate.height) < tolerance
        return widthOK && heightOK
    }

    // Recognizing which zone a window is CURRENTLY sitting in needs to be more forgiving
    // than an exact framesMatch: some apps enforce a minimum window size larger than a
    // requested zone (a Third or a Quarter is often smaller than an app's minimum), so
    // the axis that's supposed to shrink lands larger than asked instead of matching
    // exactly — e.g. a Bottom Right Quarter that can't shrink below the app's minimum
    // height. Since we set position exactly and a clamp only ever makes a dimension
    // LARGER than requested (never smaller), a shrinking axis is allowed to exceed the
    // candidate.
    //
    // That loosened check alone isn't enough, though: with no upper bound, a genuinely
    // WIDER/TALLER zone can also satisfy a narrower candidate's "at least this big" check
    // (e.g. Left Two Thirds, at 2/3 width, trivially satisfies Left Half's "width >= half,
    // minus tolerance" test too). Picking whichever candidate is the closest size fit,
    // rather than just the first one in declaration order, resolves this — and an exact
    // match is always the closest possible fit (zero discrepancy), so it always wins
    // this way with no separate exact-match pass needed.
    private static func closestZoneMatch<T>(
        _ frame: NSRect, _ candidates: [(T, NSRect)], looseWidth: Bool, looseHeight: Bool
    ) -> T? {
        candidates
            .filter { zoneMatch(frame, $0.1, looseWidth: looseWidth, looseHeight: looseHeight) }
            .min {
                abs($0.1.width - frame.width) + abs($0.1.height - frame.height)
                    < abs($1.1.width - frame.width) + abs($1.1.height - frame.height)
            }?.0
    }

    // Which of Left/Centre/Right Third another window currently occupies on this screen.
    private func occupiedThirds(excluding window: AXUIElement, on screen: NSScreen) -> Set<HState> {
        let candidates: [HState] = [.leftThird, .centerThird, .rightThird]
        return occupiedStates(
            among: candidates.map { ($0, rect(for: $0, in: screen)) }, excluding: window,
            looseWidth: true, looseHeight: false)
    }

    // Which of Top/Middle/Bottom Third another window currently occupies on this screen.
    private func vOccupiedThirds(excluding window: AXUIElement, on screen: NSScreen) -> Set<VState> {
        let candidates: [VState] = [.topThird, .middleThird, .bottomThird]
        return occupiedStates(
            among: candidates.map { ($0, vRect(for: $0, in: screen)) }, excluding: window,
            looseWidth: false, looseHeight: true)
    }

    // Shared by occupiedThirds/vOccupiedThirds: which of the given candidate states —
    // from any app, checked live rather than tracked — another on-screen window's
    // bounds currently match. A single CGWindowList query covers every on-screen
    // window in one shot, rather than walking each running app's AX tree (which would
    // mean a blocking IPC round-trip per app on every press).
    //
    // Uses the same loosened zoneMatch as recognizing the FOCUSED window's own zone
    // (currentState/vCurrentState) rather than an exact framesMatch — another app's
    // window can be just as clamped by its own minimum size as the focused one, and
    // without this, a clamped Third would silently stop counting as occupied, letting
    // this window land right on top of it instead of stepping to Centre Third/Two
    // Thirds. No closest-fit tie-break is needed here (unlike currentQuarter): the
    // three candidates for a given axis have distinct positions, so at most one can
    // ever match a given window regardless of how loose the size check is.
    private func occupiedStates<State: Hashable>(
        among candidates: [(State, NSRect)], excluding window: AXUIElement,
        looseWidth: Bool, looseHeight: Bool
    ) -> Set<State> {
        guard let excludeFrame = currentAppKitFrame(of: window),
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let ownPID = ProcessInfo.processInfo.processIdentifier

        var result = Set<State>()
        for entry in list {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let ownerPID = entry[kCGWindowOwnerPID as String] as? Int, pid_t(ownerPID) != ownPID,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = boundsDict["X"], let y = boundsDict["Y"],
                  let w = boundsDict["Width"], let h = boundsDict["Height"]
            else { continue }

            let appKitFrame = NSRect(x: x, y: primaryH - (y + h), width: w, height: h)
            if Self.framesMatch(appKitFrame, excludeFrame) { continue }  // this is `window` itself
            for (state, rect) in candidates
            where Self.zoneMatch(appKitFrame, rect, looseWidth: looseWidth, looseHeight: looseHeight) {
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

    // Same as adjacentScreen(to:direction:), mirrored onto the vertical axis: the
    // nearest monitor positioned immediately above/below this one. AppKit's Y axis
    // increases upward, so "up" means a higher minY.
    private func vAdjacentScreen(to screen: NSScreen, direction: VDirection) -> NSScreen? {
        let tolerance: CGFloat = 2
        let others = NSScreen.screens.filter { $0 !== screen }
        switch direction {
        case .up:
            return others
                .filter { $0.frame.minY >= screen.frame.maxY - tolerance }
                .min { $0.frame.minY < $1.frame.minY }
        case .down:
            return others
                .filter { $0.frame.maxY <= screen.frame.minY + tolerance }
                .max { $0.frame.maxY < $1.frame.maxY }
        }
    }

    // Accepts an AppKit-coordinate rect and applies it via AXUIElement (Quartz coords).
    // sizeFirst overrides the automatic order detection below — pass true when the
    // move crosses screens of different resolutions, where an area-only comparison
    // isn't enough to pick the safe order (see the cross-monitor call sites).
    private func setFrame(_ appKitFrame: NSRect, for window: AXUIElement, on screen: NSScreen, sizeFirst: Bool? = nil) {
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
        // Compared by area (not just width) so this is correct for vertical moves too,
        // where width never changes — area comparison reduces to the width-only check
        // whenever height is constant, so horizontal moves are unaffected.
        let isGrowing = sizeFirst ?? ((currentAppKitFrame(of: window)?.area ?? 0) < appKitFrame.area)
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

        // Some apps refuse to shrink below their own minimum window size — e.g. a
        // Bottom Third target is often shorter than an app's minimum height. Our
        // position write already placed the requested edge, so when the size write
        // gets silently clamped larger than asked, the leftover height spills past the
        // opposite edge (a short bottom-zone target can end up with its excess height
        // pushed below the screen, under the Dock, instead of clamped size growing back
        // toward where the window came from). Re-clamp position so the window's actual
        // (possibly-clamped) size stays fully inside the screen whenever it can fit,
        // sacrificing exact placement on the edge the app couldn't honor rather than
        // letting the window hang off-screen.
        if let actual = currentAppKitFrame(of: window) {
            let bounds = screen.visibleFrame
            var clamped = actual.origin
            if actual.width <= bounds.width {
                clamped.x = min(max(actual.minX, bounds.minX), bounds.maxX - actual.width)
            }
            if actual.height <= bounds.height {
                clamped.y = min(max(actual.minY, bounds.minY), bounds.maxY - actual.height)
            }
            if clamped != actual.origin {
                var repos = CGPoint(x: clamped.x, y: primaryH - (clamped.y + actual.height))
                if let reposVal = AXValueCreate(.cgPoint, &repos) {
                    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, reposVal)
                }
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
