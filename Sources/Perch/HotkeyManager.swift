import AppKit
import CoreGraphics

final class HotkeyManager {
    static let shared = HotkeyManager()

    // Set true while the preferences window is recording a new shortcut
    // so we pass events through without acting on them.
    var isPaused = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var isRunning: Bool {
        guard let tap = eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    func start() {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            // macOS converts Ctrl+leftMouse → rightMouse before cgSessionEventTap sees it
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.tapDisabledByTimeout.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: tapCallback,
            userInfo: selfPtr
        ) else {
            print("[Perch] Could not create event tap — grant Accessibility access and relaunch.")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if the system disabled it due to timeout.
        if type == .tapDisabledByTimeout {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passRetained(event)
        }

        switch type {
        case .leftMouseDown:
            let consume = DragManager.shared.mouseDown(at: event.location, flags: event.flags, isRightButton: false)
            return consume ? nil : Unmanaged.passRetained(event)
        case .rightMouseDown:
            let consume = DragManager.shared.mouseDown(at: event.location, flags: event.flags, isRightButton: true)
            return consume ? nil : Unmanaged.passRetained(event)

        case .leftMouseDragged, .rightMouseDragged:
            let consume = DragManager.shared.mouseDragged(at: event.location)
            return consume ? nil : Unmanaged.passRetained(event)

        case .leftMouseUp, .rightMouseUp:
            let consume = DragManager.shared.mouseUp(at: event.location)
            return consume ? nil : Unmanaged.passRetained(event)

        default: break
        }

        guard type == .keyDown, !isPaused else { return Unmanaged.passRetained(event) }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let relevant: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
        let flags = event.flags.intersection(relevant)
        let pressed = Hotkey(keyCode: keyCode, modifierFlags: flags.rawValue)

        guard let action = Config.shared.bindings.first(where: { $0.value == pressed })?.key else {
            return Unmanaged.passRetained(event)
        }

        // Suppress snap hotkeys while a drag is in progress — pressing an arrow key
        // mid-drag should not accidentally snap the window being dragged.
        if DragManager.shared.isActiveDrag {
            return Unmanaged.passRetained(event)
        }

        // Fire the snap synchronously so it captures the correct focused window right now.
        // An async dispatch would race with rapid clicks that change focus, causing the
        // wrong window to be snapped.
        WindowManager.shared.snap(action)
        return nil  // consume — don't forward to the app
    }
}

// C-callable callback; captures nothing, receives self via userInfo.
private func tapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let ptr = userInfo else { return Unmanaged.passRetained(event) }
    return Unmanaged<HotkeyManager>.fromOpaque(ptr).takeUnretainedValue()
        .handle(type: type, event: event)
}
