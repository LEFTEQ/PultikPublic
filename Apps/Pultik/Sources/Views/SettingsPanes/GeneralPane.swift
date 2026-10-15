import SwiftUI

/// Launch behaviour, the summon hotkey, the todo project, and where the
/// settings file lives.
struct GeneralPane: View {
    let store: StatusStore

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginItemError: String?
    @State private var todoProjectField = StatusStore.shared.todoProject ?? ""
    @State private var editorChoice = StatusStore.shared.codeEditor ?? ""
    /// Read once, not per body evaluation: `Preferences.load()` is a file read,
    /// a full JSON decode and every migration, and a SwiftUI body can run many
    /// times a second. The hotkey only applies after a relaunch anyway.
    @State private var hotkey = Preferences.load().hotkey

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
                    Text(hotkey)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Edit \"hotkey\" in settings.json (e.g. \"cmd+option+space\") — applies after relaunch. Default: option+space.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Project") {
                    TextField("project slug", text: $todoProjectField)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit(applyTodoProject)
                }
                HStack {
                    Button("Apply") { applyTodoProject() }
                        .disabled(todoProjectField.trimmingCharacters(in: .whitespaces)
                                  == (StatusStore.shared.todoProject ?? ""))
                    Spacer()
                }
                Text(TodoStore.shared.isReachable
                     ? "Reading \(VitrinkaClient.shared.origin) — \(TodoStore.shared.openTodos.count) open"
                     : "\(VitrinkaClient.shared.origin) unreachable — off the mesh, or not signed in (vitrinka login)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Todos")
            } footer: {
                Text("Todos live in vitrinka (the panel reads the CLI's sign-in; nothing is stored here). The project is where the panel's own writers file — a promoted note, an expiry-radar reminder; sessions file into their checkout's project.")
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

    /// Empty means "unset": the panel's writers then refuse with a pointer
    /// here rather than filing into a guessed project.
    private func applyTodoProject() {
        let trimmed = todoProjectField.trimmingCharacters(in: .whitespaces)
        todoProjectField = trimmed
        store.setTodoProject(trimmed.isEmpty ? nil : trimmed)
    }
}
