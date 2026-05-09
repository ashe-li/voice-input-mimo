import SwiftUI

/// Two shortcut slots — primary + secondary. Each picks a `ShortcutBinding.Preset`.
struct ShortcutsPane: View {
    @Environment(SettingsViewModel.self) private var vm

    var body: some View {
        @Bindable var vm = vm

        Form {
            Section {
                Picker("Shortcut 1", selection: $vm.primaryShortcut) {
                    ForEach(ShortcutBinding.Preset.allCases, id: \.self) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                Picker("Shortcut 2", selection: $vm.secondaryShortcut) {
                    ForEach(ShortcutBinding.Preset.allCases, id: \.self) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
            } header: {
                SectionHeading("Shortcuts", subtitle: "Primary + secondary push-to-talk binding")
            }

            Section {
                HStack {
                    Spacer()
                    Button("Save") { vm.save() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Shortcuts")
    }
}

#if DEBUG
#Preview("ShortcutsPane") {
    ShortcutsPane()
        .environment(SettingsViewModel())
        .frame(width: 560, height: 360)
}
#endif
