import AppKit

// Shared Accessibility hit-testing used by both drag targeting (DragManager) and
// occlusion checks (WindowManager), so the two can never disagree about which
// window is at a point.
enum AX {
    // Topmost window at a Quartz-coordinate (top-left origin) point.
    static func window(at point: CGPoint) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var ref: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &ref) == .success,
              let element = ref
        else { return nil }
        return containingWindow(of: element)
    }

    // The window containing an element: one kAXWindowAttribute read (a single IPC
    // round-trip), falling back to walking the parent chain for apps that don't
    // implement the attribute.
    static func containingWindow(of element: AXUIElement) -> AXUIElement? {
        var winRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &winRef) == .success,
           let winRef, CFGetTypeID(winRef) == AXUIElementGetTypeID() {
            return (winRef as! AXUIElement)
        }

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
}
