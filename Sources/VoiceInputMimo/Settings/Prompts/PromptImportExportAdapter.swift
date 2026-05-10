import AppKit
import Foundation

/// Thin AppKit adapter that opens NSSavePanel / NSOpenPanel from SwiftUI
/// callers. Kept `@MainActor` because both panels must run on the main
/// thread, and isolated to the AppKit boundary so no SwiftUI view imports
/// AppKit directly.
@MainActor
enum PromptImportExportAdapter {
    /// Show NSSavePanel and write `bundle` as JSON to the chosen path. Returns
    /// the chosen URL on success, nil if the user cancelled.
    static func exportBundle(_ bundle: PromptBundle, suggestedName: String = "prompt-bundle.json") throws -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Prompt Bundle"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let data = try PromptIO.encode(bundle)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Show NSOpenPanel and decode the chosen JSON into a `PromptBundle`.
    /// Returns nil if the user cancelled.
    static func importBundle() throws -> PromptBundle? {
        let panel = NSOpenPanel()
        panel.title = "Import Prompt Bundle"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let data = try Data(contentsOf: url)
        return try PromptIO.decode(data)
    }
}
