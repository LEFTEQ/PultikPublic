import SwiftUI

/// Launch behaviour, the summon hotkey, the code editor, and where the
/// settings file lives.
struct GeneralPane: View {
    let store: StatusStore

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginItemError: String?
    @State private var editorChoice = StatusStore.shared.codeEditor ?? ""
    /// Read once, not per body evaluation: `Preferences.load()` is a file read,
    /// a full JSON decode and every migration, and a SwiftUI body can run many
    /// times a second. The hotkey only applies after a relaunch anyway.
    @State private var preferences = Preferences.load()

    /// The profile, and what settings.json says when it names no known one.
    private var profileLabel: String {
        let resolved = preferences.resolvedProfile.rawValue
        switch preferences.profile {
        case nil: return "\(resolved) (no profile key)"
        case resolved?: return resolved
        case let raw?: return "\(resolved) (unknown \"\(raw)\")"
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Launch Pultík at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        loginItemError = LoginItem.setEnabled(newValue)
                        launchAtLogin = LoginItem.isEnabled
                    }
                ))
                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Startup")
            }

            Section {
                LabeledContent("Summon") {
                    Text(preferences.hotkey)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Profile") {
                    Text(profileLabel)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Edit \"hotkey\" in settings.json (e.g. \"cmd+option+space\") — applies after relaunch. Default: \(preferences.resolvedProfile.hotkey). The profile fills every key settings.json leaves out; change it with pultik install --profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Code editor", selection: Binding(
                    get: { editorChoice },
                    set: { newValue in
                        editorChoice = newValue
                        store.setCodeEditor(newValue.isEmpty ? nil : newValue)
                    }
                )) {
                    Text("Automatic (\(CodeEditor.installed.first?.name ?? "none installed"))").tag("")
                    ForEach(CodeEditor.known) { editor in
                        Text(editor.isInstalled ? editor.name : "\(editor.name) — not installed")
                            .tag(editor.id)
                    }
                }
            } header: {
                Text("Paths in the palette")
            } footer: {
                Text("Paste a path into the palette: ↵ opens it, ⌘↵ opens it in this editor (a file inside its git checkout, at its :line), ⌥↵ reveals it, ⇧↵ drops a terminal there. Also /editor in the palette.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("settings.json") {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Preferences.fileURL])
                    }
                }
            } footer: {
                Text("Servers, services and the project registry are lists in that file — Pultík re-reads it on launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
