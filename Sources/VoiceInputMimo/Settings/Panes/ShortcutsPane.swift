import SwiftUI

/// Two shortcut slots — primary + secondary. Each picks a `ShortcutBinding.Preset`.
struct ShortcutsPane: View {
    @Environment(SettingsViewModel.self) private var vm

    var body: some View {
        @Bindable var vm = vm

        Form {
            Section {
                Picker("快捷鍵 1", selection: $vm.primaryShortcut) {
                    ForEach(ShortcutBinding.Preset.allCases, id: \.self) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                Picker("快捷鍵 2", selection: $vm.secondaryShortcut) {
                    ForEach(ShortcutBinding.Preset.allCases, id: \.self) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
            } header: {
                SectionHeading("快捷鍵", subtitle: "主要 + 次要 按住說話綁定")
            }

            Section {
                Toggle("啟用 Ctrl+Option+← / → 切換輸出模式",
                       isOn: $vm.cycleHotkeyEnabled)
            } header: {
                SectionHeading("輸出模式切換",
                               subtitle: "在 raw / refine / claudeCode / structure 之間切換")
            }

            Section {
                Toggle("啟用 Ctrl+Option+R 錄音但不貼上（park 模式）",
                       isOn: $vm.parkHotkeyEnabled)
            } header: {
                SectionHeading("Park 模式",
                               subtitle: "按住錄音 + 辨識；只存進歷史不貼上")
            }

            Section {
                HStack {
                    Spacer()
                    Button("儲存") { vm.save() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("快捷鍵")
    }
}

#if DEBUG
#Preview("ShortcutsPane") {
    ShortcutsPane()
        .environment(SettingsViewModel())
        .frame(width: 560, height: 360)
}
#endif
