import AppKit
import SwiftUI

/// Owned by the page, so a cleared row disappearing cannot dismiss its log.
struct DevboxClearPopover: View {
    let workspace: DevboxWorkspace
    let store: StatusStore
    let onClose: () -> Void
    @State private var preview: DevboxClearPreview?
    @State private var source: DevboxClearSourceAction = .keep
    @State private var report: DevboxClearReport?
    @State private var busy = false
    @State private var history = ""
    @State private var showLog = false
    @State private var showChanges = false
    @State private var expandedSections: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Clear this").font(.headline)
                    Text(workspace.name).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    if let box = workspace.box { Text("Box \(box.name)").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Button("Close", action: onClose).disabled(busy)
            }
            ScrollViewReader { scroll in
              ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Stops this workspace, removes its runtime entry and releases its ports. Your branch, local source, guest source and persistent data are preserved.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    if let preview {
                        Text("What are the changes?").font(.subheadline.weight(.semibold))
                        Text(preview.explanation).font(.caption).foregroundStyle(.secondary)
                        if let path = preview.path { Text(path).font(.system(.caption2, design: .monospaced)).textSelection(.enabled) }
                        disclosure("Modified and untracked files", text: preview.status.isEmpty ? "None" : preview.status)
                        disclosure("Diff · staged and unstaged", text: preview.diff.isEmpty ? "No tracked changes. Secret-file contents are excluded; untracked files are listed above." : preview.diff)
                        disclosure("Local commits", text: preview.commits.isEmpty ? "No commits beyond known remote refs." : preview.commits)
                        ForEach(Array(preview.additionalSources.enumerated()), id: \.offset) { _, other in
                            disclosure("Additional source · \(other.path ?? "unavailable") · kept", text: other.status + "\n" + other.diff + "\nLocal commits:\n" + other.commits)
                        }
                        Text("Commit comparison uses local remote refs and may be stale. Clearing never deletes the branch or its commits.")
                            .font(.caption2).foregroundStyle(.secondary)
                        if preview.canRemove {
                            Picker("Local worktree", selection: $source) {
                                ForEach(DevboxClearSourceAction.allCases) { action in Text(action.title).tag(action) }
                            }
                            .disabled(busy || report?.ok == true)
                            if source == .discard {
                                Text("Modified, untracked and ignored files in this worktree will be deleted. Its branch and commits remain in the repository.")
                                    .font(.caption).foregroundStyle(.red)
                            } else if source == .backup {
                                Text("Saves the complete local worktree under ~/Backups/pultik-worktrees before removal. Guest source and persistent data stay preserved.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        ProgressView("Reading local changes…")
                    }
                    if let report {
                        Divider()
                        Label(report.ok ? "Cleared" : "Why it failed", systemImage: report.ok ? "checkmark.circle" : "exclamationmark.circle")
                            .foregroundStyle(report.ok ? Color.green : Color.orange)
                            .id("clear-result")
                        Text(report.summary).font(.callout).textSelection(.enabled)
                        ForEach(Array(report.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(diagnostic.code).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                                if let detail = diagnostic.detail { Text(detail).font(.caption).textSelection(.enabled) }
                                if let fix = diagnostic.fix { Text(fix).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                            }
                        }
                        if !report.next.isEmpty { disclosure("Recovery instructions", text: report.next.joined(separator: "\n")) }
                    }
                    DisclosureGroup("Full command log", isExpanded: $showLog) {
                        Text(history.isEmpty ? preview?.log ?? "No command has run." : history)
                            .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 410)
            .onChange(of: report?.summary) { _, summary in
                if summary != nil { scroll.scrollTo("clear-result", anchor: .top) }
            }
            }
            HStack {
                Button("Refresh changes") { refresh() }.disabled(busy)
                Button("Copy log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(history.isEmpty ? preview?.log ?? "" : history, forType: .string)
                }
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                    Text("Working…").font(.caption)
                } else if report?.ok != true {
                    if report != nil {
                        Button(needsUnhold ? "Unhold and clear" : "Inspect and retry clear") { perform(recover: true) }
                    } else {
                        Button(source.button, role: source == .discard ? .destructive : nil) { perform(recover: false) }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .disabled(preview == nil)
        }
        .padding(18)
        .frame(width: 580)
        .task { refresh() }
        .interactiveDismissDisabled(busy)
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: PanelDriver.paletteNotification)) { note in
            guard note.userInfo?["cmd"] as? String == "clear-action", let action = note.userInfo?["text"] as? String else { return }
            switch action {
            case "clear": perform(recover: false)
            case "keep", "backup", "discard":
                if !busy, report?.ok != true, let selection = DevboxClearSourceAction(rawValue: action), selection == .keep || preview?.canRemove == true { source = selection }
            case "show-log": showLog = true
            case "show-changes": showChanges = true
            case "refresh": refresh()
            case "inspect": perform(recover: true)
            case "close": if !busy { onClose() }
            default: break
            }
        }
        #endif
    }

    private var needsUnhold: Bool {
        report?.diagnostics.contains { $0.fix?.hasPrefix("devbox unhold ") == true } == true
    }

    private func disclosure(_ title: String, text: String) -> some View {
        DisclosureGroup(title, isExpanded: Binding(get: { showChanges || expandedSections.contains(title) }, set: { expanded in
            if expanded { expandedSections.insert(title) } else { expandedSections.remove(title) }
        })) {
            Text(text).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func refresh() {
        guard !busy else { return }
        busy = true
        Task {
            let next = await DevboxClient.shared.clearPreview(workspace)
            preview = next
            if !next.canRemove { source = .keep }
            busy = false
        }
    }

    private func perform(recover: Bool) {
        guard let preview, !busy else { return }
        busy = true
        Task {
            if recover {
                let inspection = await DevboxClient.shared.inspectClear(workspace, releaseHold: needsUnhold)
                history += "\n\n" + inspection.log
                guard inspection.ok else {
                    report = inspection
                    showLog = true
                    busy = false
                    return
                }
            }
            let outcome = await DevboxClient.shared.clear(workspace, preview: preview, source: source)
            report = outcome
            history += "\n\n" + outcome.log
            if !outcome.ok { showLog = true }
            busy = false
            await store.refreshDevboxNow()
        }
    }
}
