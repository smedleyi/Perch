import Carbon.HIToolbox
import CoreGraphics
import Foundation

enum DragModifier: Int, CaseIterable {
    case control
    case option
    case command
    case controlOption

    var flags: CGEventFlags {
        switch self {
        case .control:       return [.maskControl]
        case .option:        return [.maskAlternate]
        case .command:       return [.maskCommand]
        case .controlOption: return [.maskControl, .maskAlternate]
        }
    }

    var displayName: String {
        switch self {
        case .control:       return "⌃ Control"
        case .option:        return "⌥ Option"
        case .command:       return "⌘ Command"
        case .controlOption: return "⌃⌥ Control+Option"
        }
    }
}

final class Config {
    static let shared = Config()

    private let userDefaults = UserDefaults.standard
    private let bindingsKey = "hotkeyBindings"
    private let dragModifierKey = "dragModifier"

    var menuBarIconHidden: Bool {
        get { userDefaults.bool(forKey: "menuBarIconHidden") }
        set { userDefaults.set(newValue, forKey: "menuBarIconHidden") }
    }

    var dragModifier: DragModifier {
        get { DragModifier(rawValue: userDefaults.integer(forKey: dragModifierKey)) ?? .control }
        set { userDefaults.set(newValue.rawValue, forKey: dragModifierKey) }
    }

    var bindings: [SnapAction: Hotkey] {
        get {
            guard let data = userDefaults.data(forKey: bindingsKey),
                  let raw = try? JSONDecoder().decode([String: Hotkey].self, from: data)
            else { return Self.defaultBindings }
            var result = Self.defaultBindings
            for (key, value) in raw {
                if let action = SnapAction(rawValue: key) { result[action] = value }
            }
            return result
        }
        set {
            let raw = Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.rawValue, $0.value) })
            if let data = try? JSONEncoder().encode(raw) {
                userDefaults.set(data, forKey: bindingsKey)
            }
        }
    }

    static var defaultBindings: [SnapAction: Hotkey] {
        let opt     = CGEventFlags([.maskAlternate]).rawValue
        let optCtrl = CGEventFlags([.maskAlternate, .maskControl]).rawValue
        return [
            // Windows-style: Option + arrows
            .leftHalf:           Hotkey(keyCode: kVK_LeftArrow,  modifierFlags: opt),
            .rightHalf:          Hotkey(keyCode: kVK_RightArrow, modifierFlags: opt),
            .maximize:           Hotkey(keyCode: kVK_UpArrow,    modifierFlags: opt),
            .center:             Hotkey(keyCode: kVK_DownArrow,  modifierFlags: opt),
            // Quarters and halves use Option+Ctrl to stay out of the way
            .topLeftQuarter:     Hotkey(keyCode: kVK_ANSI_U,     modifierFlags: optCtrl),
            .topRightQuarter:    Hotkey(keyCode: kVK_ANSI_I,     modifierFlags: optCtrl),
            .bottomLeftQuarter:  Hotkey(keyCode: kVK_ANSI_J,     modifierFlags: optCtrl),
            .bottomRightQuarter: Hotkey(keyCode: kVK_ANSI_K,     modifierFlags: optCtrl),
            .topHalf:            Hotkey(keyCode: kVK_ANSI_T,     modifierFlags: optCtrl),
            .bottomHalf:         Hotkey(keyCode: kVK_ANSI_B,     modifierFlags: optCtrl),
        ]
    }
}
