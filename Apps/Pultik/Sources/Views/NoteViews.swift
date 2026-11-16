import AppKit
import SwiftUI

/// One note, everywhere it appears: the right rail (compact), the palette's
/// results section, and the `.notes` page (both wide).
///
/// Collapsed it is exactly one line — text truncated at the tail, age at the
/// trailing edge — because a pasted 40-line note used to render in full and
/// push the rest of the rail off-screen. Expansion is opt-in, animated, and
/// bounded: the body can never grow past `Metrics.expandedMaxHeight`, so
/// opening a note can't re-create the blocking it was meant to fix.
struct NoteRow: View {
    enum Style {
        /// The 280px right rail — link-row scale, no hover actions.
        case rail
        /// The 680px center column — inbox scale, hover action cluster.
        case wide
    }

    enum Metrics {
        static let expandedMaxHeight: CGFloat = 220
    }

    let note: SavedNote
    var style: Style = .wide
    var selected = false
    var expanded = false
    /// Tapping the row body — read, never destroy.
    let onToggle: () -> Void
    /// ⌥-click in the rail, the ✕ in the wide idioms. Nil = not removable here.
    var onRemove: (() -> Void)?
    var onCopy: (() -> Void)?
    var onEdit: (() -> Void)?

    @State private var hovering = false

    private var textSize: CGFloat { style == .rail ? 10.5 : 12.5 }
    private var ageSize: CGFloat { style == .rail ? 9 : 10 }

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 4 : 0) {
            header
            if expanded {
                expandedBody
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, style == .rail ? 5 : 4)
        .background(background, in: RoundedRectangle(cornerRadius: style == .rail ? 7 : 6))
        .overlay(
            RoundedRectangle(cornerRadius: style == .rail ? 7 : 6)
                .strokeBorder(selected ? Theme.accent.opacity(0.35) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            // ⌥-click removes without ever having been a plain click — the
            // row body stays a read verb, so a truncated note can't be
            // deleted by a stray tap on text you couldn't fully see.
            if NSEvent.modifierFlags.contains(.option), let onRemove {
                onRemove()
            } else {
                onToggle()
            }
        }
        .help(helpText)
        // The row is tap-only visually; give assistive tech the same verbs.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Note: \(note.oneLine)")
        .accessibilityValue(expanded ? note.text : "collapsed")
        .accessibilityHint("noted \(note.createdAt.shortAge) ago")
        .accessibilityAction { onToggle() }
        .accessibilityActions {
            if let onCopy { Button("Copy note") { onCopy() } }
            if let onEdit { Button("Edit note") { onEdit() } }
            if let onRemove { Button("Remove note") { onRemove() } }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: "square.text.square")
                .font(.system(size: style == .rail ? 9 : 10))
                .foregroundStyle(.tertiary)
            Text(note.oneLine)
                .font(.system(size: textSize))
                .foregroundStyle(style == .rail ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if style == .wide, hovering || selected {
                actions
            }
            Text(note.createdAt.shortAge)
                .font(.system(size: ageSize, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.quaternary)
        }
    }

    /// The full text, capped and scrollable. `textSelection` makes an expanded
    /// note something you can get back OUT — a spec you can read but not
    /// retrieve is half a feature.
    private var expandedBody: some View {
        ScrollView(.vertical, showsIndicators: true) {
            Text(note.text)
                .font(.system(size: textSize))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, style == .rail ? 15 : 16)
                .padding(.trailing, 2)
                .padding(.bottom, 2)
        }
        .frame(maxHeight: Metrics.expandedMaxHeight)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    @ViewBuilder
    private var actions: some View {
        if let onCopy {
            NoteAction(systemImage: "doc.on.doc", help: "Copy note (⌘C)", action: onCopy)
        }
        if let onEdit {
            NoteAction(systemImage: "pencil", help: "Edit note", action: onEdit)
        }
        if let onRemove {
            NoteAction(systemImage: "xmark.circle.fill", help: "Remove note",
                       tone: .orange, action: onRemove)
        }
    }

    private var background: Color {
        if selected { return Theme.accent.opacity(0.16) }
        return hovering ? Color.primary.opacity(0.06) : .clear
    }

    private var helpText: String {
        let age = "noted \(note.createdAt.shortAge) ago"
        if style == .rail {
            return expanded ? age : "\(age) — click to read, ⌥-click to remove"
        }
        return age
    }
}

private struct NoteAction: View {
    let systemImage: String
    let help: String
    var tone: Color = .secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10))
                .foregroundStyle(tone)
        }
        .buttonStyle(.plain)
        .help(help)
        // .help is a tooltip, not reliably the VoiceOver label.
        .accessibilityLabel(help)
    }
}

/// What `.notes` offers for the field's text: the paste read back in full
/// (bounded like an expanded note) before it is saved. The palette bar is one
/// line, so this row is where a long paste is actually readable.
struct NoteDraftRow: View {
    let text: String
    var selected = false
    /// "↵" when the draft is the only row, "⌘↵" when matches sit under it.
    let shortcut: String
    let onCreate: () -> Void

    @State private var hovering = false

    private var lineCount: Int {
        text.split(whereSeparator: \.isNewline).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "plus.square")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.accent)
                Text("New note")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("\(lineCount) \(lineCount == 1 ? "line" : "lines") · \(text.count) chars")
                    .font(.system(size: 10, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                Text("\(shortcut) create")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            ScrollView(.vertical, showsIndicators: true) {
                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 16)
                    .padding(.trailing, 2)
                    .padding(.bottom, 2)
            }
            .frame(maxHeight: NoteRow.Metrics.expandedMaxHeight)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Theme.accent.opacity(selected ? 0.16 : hovering ? 0.10 : 0.06),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Theme.accent.opacity(selected ? 0.35 : 0.15), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onCreate)
        .help("Save as a note")
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Create note")
        .accessibilityValue(text)
        .accessibilityAction { onCreate() }
    }
}

// MARK: - .notes mode — the full surface

/// Every note, full width, filterable. The rail is a glance capped at five;
/// this is where the rest live and where the verbs that need room happen —
/// edit, copy, remove.
struct NotesPageView: View {
    let store: NoteStore
    /// Pre-filtered by the panel so rows and ↑/↓ stay in step.
    let notes: [SavedNote]
    /// The field's text, offered as a new note above the matches.
    let newNote: String?
    let newNoteID: String
    let onCreate: () -> Void
    var selectedID: String?
    let isSelected: (String) -> Bool
    let expandedID: String?
    /// Which note is being edited. Owned by the panel so its key handler can
    /// see it: Esc must cancel the edit rather than close the window out from
    /// under a half-typed draft.
    @Binding var editingID: String?
    let onToggle: (SavedNote) -> Void
    let onBack: () -> Void

    @State private var draft = ""
    @FocusState private var editorFocused: Bool

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    header
                    if let newNote {
                        NoteDraftRow(
                            text: newNote,
                            selected: isSelected(newNoteID),
                            // Bare ↵ reads the top match when there is one.
                            shortcut: notes.isEmpty ? "↵" : "⌘↵",
                            onCreate: onCreate
                        )
                        .id(newNoteID)
                    } else if notes.isEmpty {
                        Text("no notes — type or paste one, ↵ saves it")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                    ForEach(notes) { note in
                        if editingID == note.id {
                            editor(for: note)
                                .id("note:\(note.id)")
                        } else {
                            NoteRow(
                                note: note,
                                style: .wide,
                                selected: isSelected("note:\(note.id)"),
                                expanded: expandedID == note.id,
                                onToggle: { onToggle(note) },
                                onRemove: { store.remove(id: note.id) },
                                onCopy: { copy(note) },
                                onEdit: { beginEditing(note) }
                            )
                            .id("note:\(note.id)")
                            .contextMenu {
                                Button("Edit") { beginEditing(note) }
                                Button("Copy") { copy(note) }
                                Divider()
                                Button("Remove", role: .destructive) { store.remove(id: note.id) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) { scroller.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.borderless)
            .help("Back (Esc)")
            Text("Notes")
                .font(.system(size: 14, weight: .semibold))
            Text("\(notes.count)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Text(newNote != nil && notes.isEmpty ? "↵ create" : "↵ read · ⌘C copy")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func editor(for note: SavedNote) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $draft)
                .font(.system(size: 12.5))
                .scrollContentBackground(.hidden)
                .frame(height: 140)
                .padding(6)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                .focused($editorFocused)
                .onAppear { editorFocused = true }
                // The spec says save on ⌘↵ AND blur. Cancel/Esc clear
                // `editingID` before the focus change lands, so the guard
                // keeps them from saving the discarded draft.
                .onChange(of: editorFocused) { _, focused in
                    if !focused, editingID == note.id { commitEdit(note) }
                }
            HStack(spacing: 8) {
                Text("⌘↵ save · Esc cancel")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { editingID = nil }
                    .buttonStyle(.borderless)
                Button("Save") { commitEdit(note) }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func beginEditing(_ note: SavedNote) {
        draft = note.text
        editingID = note.id
    }

    private func commitEdit(_ note: SavedNote) {
        // A rejected edit (emptied text) keeps the editor open — closing it
        // would look like a save while the old note silently survives.
        if store.update(id: note.id, text: draft) {
            editingID = nil
        }
    }

    private func copy(_ note: SavedNote) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note.text, forType: .string)
    }
}
