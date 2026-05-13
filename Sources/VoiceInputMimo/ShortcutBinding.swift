import CoreGraphics
import Foundation

struct ShortcutBinding: Equatable {
    enum Preset: String, CaseIterable {
        case disabled
        case function
        case controlOptionSpace
        case controlOptionV
        case commandShiftSpace

        var title: String {
            switch self {
            case .disabled: return "Disabled"
            case .function: return "Fn"
            case .controlOptionSpace: return "Control + Option + Space"
            case .controlOptionV: return "Control + Option + V"
            case .commandShiftSpace: return "Command + Shift + Space"
            }
        }

        var keyCode: Int64? {
            switch self {
            case .disabled, .function: return nil
            case .controlOptionSpace, .commandShiftSpace: return 49
            case .controlOptionV: return 9
            }
        }

        var requiredFlags: CGEventFlags {
            switch self {
            case .disabled, .function:
                return []
            case .controlOptionSpace, .controlOptionV:
                return [.maskControl, .maskAlternate]
            case .commandShiftSpace:
                return [.maskCommand, .maskShift]
            }
        }
    }

    static let primaryKey = "shortcutPrimaryPreset"
    static let secondaryKey = "shortcutSecondaryPreset"
    static let cycleHotkeyKey = "cycleHotkeyEnabled"

    let preset: Preset

    var isEnabled: Bool { preset != .disabled }
    var title: String { preset.title }

    static func loadPrimary() -> ShortcutBinding {
        let raw = UserDefaults.standard.string(forKey: primaryKey) ?? Preset.function.rawValue
        return ShortcutBinding(preset: Preset(rawValue: raw) ?? .function)
    }

    static func loadSecondary() -> ShortcutBinding {
        let raw = UserDefaults.standard.string(forKey: secondaryKey) ?? Preset.disabled.rawValue
        return ShortcutBinding(preset: Preset(rawValue: raw) ?? .disabled)
    }

    static func loadAll() -> [ShortcutBinding] {
        [loadPrimary(), loadSecondary()].filter(\.isEnabled)
    }

    static func save(primary: Preset, secondary: Preset) {
        UserDefaults.standard.set(primary.rawValue, forKey: primaryKey)
        UserDefaults.standard.set(secondary.rawValue, forKey: secondaryKey)
    }

    /// Ctrl+Option+arrow output-mode cycle hotkey. Default true (existing
    /// behavior) when the key has never been written.
    static func loadCycleHotkeyEnabled() -> Bool {
        (UserDefaults.standard.object(forKey: cycleHotkeyKey) as? Bool) ?? true
    }

    static func saveCycleHotkeyEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: cycleHotkeyKey)
    }

    func matchesKeyDown(event: CGEvent) -> Bool {
        guard let keyCode = preset.keyCode else { return false }
        return event.getIntegerValueField(.keyboardEventKeycode) == keyCode
            && event.flags.containsAll(preset.requiredFlags)
    }
}

extension Notification.Name {
    /// Posted after `ShortcutBinding.save` so the KeyMonitor EventTap thread
    /// can drop its cached snapshot.
    static let shortcutBindingDidChange = Notification.Name("voiceInputMimo.shortcutBindingDidChange")
}

extension CGEventFlags {
    func containsAll(_ required: CGEventFlags) -> Bool {
        intersection(required) == required
    }
}
