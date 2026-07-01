import AppKit

enum SnapAction: String, Codable, CaseIterable {
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf
    case maximize
    case center
    case topLeftQuarter
    case topRightQuarter
    case bottomLeftQuarter
    case bottomRightQuarter

    var displayName: String {
        switch self {
        case .leftHalf:          return "Left Half"
        case .rightHalf:         return "Right Half"
        case .topHalf:           return "Top Half"
        case .bottomHalf:        return "Bottom Half"
        case .maximize:          return "Maximize"
        case .center:            return "Center (70%)"
        case .topLeftQuarter:    return "Top Left Quarter"
        case .topRightQuarter:   return "Top Right Quarter"
        case .bottomLeftQuarter: return "Bottom Left Quarter"
        case .bottomRightQuarter:return "Bottom Right Quarter"
        }
    }

    // Returns target frame in AppKit (bottom-left origin) coordinates.
    func targetFrame(in screen: NSScreen) -> NSRect {
        let f = screen.visibleFrame
        switch self {
        case .leftHalf:
            return NSRect(x: f.minX, y: f.minY, width: f.width / 2, height: f.height)
        case .rightHalf:
            return NSRect(x: f.midX, y: f.minY, width: f.width / 2, height: f.height)
        case .topHalf:
            return NSRect(x: f.minX, y: f.midY, width: f.width, height: f.height / 2)
        case .bottomHalf:
            return NSRect(x: f.minX, y: f.minY, width: f.width, height: f.height / 2)
        case .maximize:
            return f
        case .center:
            let w = f.width * 0.7, h = f.height * 0.7
            return NSRect(x: f.midX - w / 2, y: f.midY - h / 2, width: w, height: h)
        case .topLeftQuarter:
            return NSRect(x: f.minX, y: f.midY, width: f.width / 2, height: f.height / 2)
        case .topRightQuarter:
            return NSRect(x: f.midX, y: f.midY, width: f.width / 2, height: f.height / 2)
        case .bottomLeftQuarter:
            return NSRect(x: f.minX, y: f.minY, width: f.width / 2, height: f.height / 2)
        case .bottomRightQuarter:
            return NSRect(x: f.midX, y: f.minY, width: f.width / 2, height: f.height / 2)
        }
    }
}
