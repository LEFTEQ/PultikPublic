import SwiftUI

/// The Files changed tab's tree (PR workbench WP4, D6), the side column's
/// first pane: a filter keeps the matches and their folders, a folder row
/// folds, a file row brings its diff to the top. The file at the top of the
/// canvas is the selected row, and the list follows it.
struct FileTreeView: View {
    let files: [ChangedFile]
    /// The path of the file at the top of the canvas.
    let current: String?
    let select: (String) -> Void
    @State private var filter = ""
    @State private var folded: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let tree = FileTree(files, filter: filter, folded: folded)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10)).foregroundStyle(Theme.ink3)
                TextField("Filter files", text: $filter)
                    .textFieldStyle(.plain)
                    .font(Theme.Typo.meta)
                if !filter.isEmpty {
                    Button { filter = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(Theme.ink3)
                    }
                    .buttonStyle(.plain)
                    .help("Clear the filter")
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
            .padding(8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(tree.rows) { row in
                            rowView(row).id(row.id)
                        }
                        if tree.rows.isEmpty {
                            Text("No file matches").font(Theme.Typo.meta).foregroundStyle(Theme.ink3).padding(8)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
                .onChange(of: current) { _, path in
                    guard let path else { return }
                    withAnimation(Theme.Motion.focus(reduceMotion)) { proxy.scrollTo(path) }
                }
            }
        }
    }

    private func rowView(_ row: FileTree.Row) -> some View {
        let selected = !row.isFolder && row.id == current
        return Button {
            if row.isFolder {
                withAnimation(Theme.Motion.disclosure(reduceMotion)) { folded.formSymmetricDifference([row.path]) }
            } else {
                select(row.path)
            }
        } label: {
            HStack(spacing: 5) {
                if row.isFolder {
                    Image(systemName: folded.contains(row.path) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.ink3).frame(width: 10)
                    Image(systemName: "folder.fill").font(.system(size: 10)).foregroundStyle(Theme.ink3)
                } else {
                    Text(row.letter ?? "M").font(Theme.Typo.micro).foregroundStyle(tone(row.letter)).frame(width: 10)
                }
                Text(row.name)
                    .font(Theme.Typo.meta)
                    .foregroundStyle(row.isFolder ? Theme.ink2 : Theme.ink)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if !row.isFolder {
                    Text(verbatim: "+\(row.additions)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.ok)
                    Text(verbatim: "−\(row.deletions)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.danger)
                }
            }
            .padding(.leading, CGFloat(row.depth) * 12 + 4)
            .padding(.trailing, 6)
            .frame(height: 22)
            .background(selected ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.kbd))
            .overlay(alignment: .leading) {
                if selected { Capsule().fill(Theme.accent).frame(width: 2, height: 14) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(row.path)
    }

    private func tone(_ letter: String?) -> Color {
        switch letter {
        case "A": Theme.ok
        case "D": Theme.danger
        default: Theme.ink2
        }
    }
}
