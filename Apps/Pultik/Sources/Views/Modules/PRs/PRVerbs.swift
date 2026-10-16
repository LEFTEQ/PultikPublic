import SwiftUI

/// What the workbench lays over its tab while a verb asks for more (PR
/// workbench D5): a confirm naming what ↵ will do, the review or edit
/// sheet, a metadata picker, or ⌘K's list of every verb and its key.
enum VerbSheet: Equatable {
    case menu
    case merge
    case confirm(ChangeRequestVerb, title: String)
    case review(ReviewEvent)
    case edit
    case pick(MetadataField)

    /// ↵ runs a confirm; every other sheet holds text, and ⌘↵ submits it.
    var isConfirm: Bool {
        switch self {
        case .merge, .confirm: true
        default: false
        }
    }
}

/// The header's verbs (D5): Merge ▾ · Review ▾ · ⋯, each verb with its letter
/// and, when it cannot run, why.
struct VerbBar: View {
    let verbs: [PRVerb]
    let mergeable: Bool
    let reach: (PRVerb) -> Void

    var body: some View {
        HStack(spacing: 6) {
            menu(.merge, title: "Merge", symbol: "arrow.triangle.merge", prominent: mergeable)
            menu(.review, title: "Review", symbol: "checkmark.bubble", prominent: false)
            menu(.more, title: nil, symbol: "ellipsis", prominent: false)
        }
    }

    @ViewBuilder
    private func menu(_ group: PRVerb.Group, title: String?, symbol: String, prominent: Bool) -> some View {
        if prominent {
            menuBody(group, title: title, symbol: symbol).buttonStyle(.glassProminent).tint(Theme.accent)
        } else {
            menuBody(group, title: title, symbol: symbol).buttonStyle(.glass)
        }
    }

    private func menuBody(_ group: PRVerb.Group, title: String?, symbol: String) -> some View {
        Menu {
            ForEach(verbs.filter { $0.group == group }) { verb in
                Button { reach(verb) } label: {
                    Label(verb.key.map { "\(verb.title)    \($0.uppercased())" } ?? verb.title, systemImage: verb.symbol)
                }
                .disabled(!verb.enabled)
                .help(verb.disabledReason ?? verb.title)
            }
            if group == .more {
                Divider()
                Text("⌘K lists every verb with its key")
            }
        } label: {
            if let title { Label(title, systemImage: symbol) } else { Image(systemName: symbol) }
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
    }
}

/// One sheet over the workbench's tab: its title, its body, and the key
/// that runs it — ↵ for a confirm, ⌘↵ for anything typed.
struct VerbSheetCard<Content: View>: View {
    let title: String
    let confirm: Bool
    let action: String?
    var enabled = true
    var busy = false
    var failure: String?
    let run: () -> Void
    let cancel: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Theme.Typo.title).foregroundStyle(Theme.ink)
            content()
            HStack(spacing: 8) {
                if let failure {
                    Text(failure).font(Theme.Typo.meta).foregroundStyle(Theme.danger).lineLimit(3)
                }
                Spacer(minLength: 6)
                KbdHint("esc")
                Button("Cancel", action: cancel).buttonStyle(.plain).font(Theme.Typo.meta).foregroundStyle(Theme.ink2)
                if let action {
                    KbdHint(confirm ? "↵" : "⌘↵")
                    Button(action, action: run)
                        .buttonStyle(.glassProminent)
                        .tint(Theme.accent)
                        .controlSize(.small)
                        .disabled(!enabled || busy)
                }
                if busy { ProgressView().controlSize(.mini) }
            }
        }
        .padding(14)
        .frame(width: 440, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous).strokeBorder(Theme.hairlineStrong))
        .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
    }
}

/// ⌘K: every verb in its group with its letter; a click reaches it, and the
/// letters keep working while the list is up.
struct VerbMenuList: View {
    let verbs: [PRVerb]
    let reach: (PRVerb) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach([PRVerb.Group.merge, .review, .more], id: \.self) { group in
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.rawValue).microLabel()
                    ForEach(verbs.filter { $0.group == group }) { verb in
                        Button { reach(verb) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: verb.symbol).font(.system(size: 11)).frame(width: 16)
                                    .foregroundStyle(verb.enabled ? Theme.ink2 : Theme.ink3)
                                Text(verb.title).font(Theme.Typo.body)
                                    .foregroundStyle(verb.enabled ? Theme.ink : Theme.ink3)
                                if let reason = verb.disabledReason {
                                    Text(reason).font(Theme.Typo.meta).foregroundStyle(Theme.ink3).lineLimit(1)
                                }
                                Spacer(minLength: 6)
                                if let key = verb.key { KbdHint(key.uppercased()) }
                            }
                            .frame(height: 24)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!verb.enabled)
                    }
                }
            }
        }
    }
}

/// A metadata picker (D4, D8): the repo's choices with the current set
/// checked; ⌘↵ applies the whole set. A milestone is one or none.
struct MetadataPicker: View {
    let field: MetadataField
    let choices: MetadataChoices?
    @Binding var picked: Set<String>
    @State private var filter = ""

    struct Option: Identifiable {
        let id: String
        let title: String
        var detail: String?
        var swatch: Color?
    }

    var options: [Option] {
        guard let choices else { return [] }
        switch field {
        case .labels:
            return choices.labels.map { Option(id: $0.id, title: $0.name, detail: $0.description,
                                               swatch: Color(labelHex: $0.color) ?? .gray) }
        case .assignees:
            return choices.people.map { Option(id: $0.id, title: $0.login, detail: $0.name) }
        case .reviewers:
            return choices.people.map { Option(id: $0.id, title: $0.login, detail: $0.name) }
                + choices.teams.map { Option(id: $0.id, title: $0.name, detail: "team") }
        case .milestone:
            return choices.milestones.map { Option(id: $0.id, title: $0.title,
                                                   detail: $0.dueOn.map { "due \(PultikFormat.date($0, now: Date()))" }) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Filter", text: $filter)
                .textFieldStyle(.plain)
                .font(Theme.Typo.meta)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.Radius.row))
            if choices == nil {
                SkeletonBars(widths: [0.6, 0.4, 0.5])
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let needle = filter.lowercased()
                    ForEach(options.filter { needle.isEmpty || $0.title.lowercased().contains(needle) }) { option in
                        Button { toggle(option.id) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: picked.contains(option.id) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(picked.contains(option.id) ? Theme.accent : Theme.ink3)
                                if let swatch = option.swatch { Circle().fill(swatch).frame(width: 8, height: 8) }
                                Text(option.title).font(Theme.Typo.body).foregroundStyle(Theme.ink).lineLimit(1)
                                if let detail = option.detail {
                                    Text(detail).font(Theme.Typo.meta).foregroundStyle(Theme.ink3).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(height: 22)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 220)
        }
    }

    private func toggle(_ id: String) {
        if field == .milestone {
            picked = picked.contains(id) ? [] : [id]
        } else {
            picked.formSymmetricDifference([id])
        }
    }
}
