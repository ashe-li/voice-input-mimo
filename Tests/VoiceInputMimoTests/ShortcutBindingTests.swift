import XCTest
@testable import VoiceInputMimo

final class ShortcutBindingTests: XCTestCase {
    func testDefaultShortcutsAreFnAndDisabled() {
        let defaults = UserDefaults.standard
        let oldPrimary = defaults.string(forKey: ShortcutBinding.primaryKey)
        let oldSecondary = defaults.string(forKey: ShortcutBinding.secondaryKey)
        defaults.removeObject(forKey: ShortcutBinding.primaryKey)
        defaults.removeObject(forKey: ShortcutBinding.secondaryKey)
        defer {
            defaults.set(oldPrimary, forKey: ShortcutBinding.primaryKey)
            defaults.set(oldSecondary, forKey: ShortcutBinding.secondaryKey)
        }

        XCTAssertEqual(ShortcutBinding.loadPrimary().preset, .function)
        XCTAssertEqual(ShortcutBinding.loadSecondary().preset, .disabled)
        XCTAssertEqual(ShortcutBinding.loadAll(), [ShortcutBinding(preset: .function)])
    }

    func testSaveTwoShortcutPresets() {
        let defaults = UserDefaults.standard
        let oldPrimary = defaults.string(forKey: ShortcutBinding.primaryKey)
        let oldSecondary = defaults.string(forKey: ShortcutBinding.secondaryKey)
        defer {
            defaults.set(oldPrimary, forKey: ShortcutBinding.primaryKey)
            defaults.set(oldSecondary, forKey: ShortcutBinding.secondaryKey)
        }

        ShortcutBinding.save(primary: .controlOptionSpace, secondary: .controlOptionV)

        XCTAssertEqual(ShortcutBinding.loadPrimary().preset, .controlOptionSpace)
        XCTAssertEqual(ShortcutBinding.loadSecondary().preset, .controlOptionV)
        XCTAssertEqual(ShortcutBinding.loadAll().map(\.preset), [.controlOptionSpace, .controlOptionV])
    }
}
