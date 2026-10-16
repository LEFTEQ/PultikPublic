import Foundation
import Markdown

/// A change request's description as GitHub-flavoured markdown, read by
/// Pultík itself (stay in Pultík D8): cmark-gfm's AST (swift-markdown) into
/// Pultík's own blocks, inline markup as attributed runs, and references
/// (`#123`, `@user`, SHAs) linked through the host's `AutolinkResolver`.
/// No web view and no host HTML. Raw HTML beyond `<details>`, `<img>`,
/// `<br>` and comments keeps its text and drops its tags.
indirect enum GFMBlock: Equatable {
    case heading(Int, AttributedString)
    case paragraph(AttributedString)
    case quote([GFMBlock])
    case alert(GFMAlert, [GFMBlock])
    case code(language: String?, String)
    case list(ordered: Bool, start: Int, items: [GFMItem])
    case table(GFMTable)
    case image(URL?, alt: String)
    case details(summary: AttributedString, [GFMBlock])
    case rule
}

struct GFMItem: Equatable {
    /// A task list item's box; nil for a plain item.
    var checked: Bool?
    var blocks: [GFMBlock]
}

struct GFMTable: Equatable {
    enum Alignment: Equatable { case leading, center, trailing }

    var alignments: [Alignment]
    var header: [AttributedString]
    var rows: [[AttributedString]]
}

/// GitHub's alert quotes: `> [!NOTE]` and its four siblings.
enum GFMAlert: String, CaseIterable, Equatable {
    case note, tip, important, warning, caution
}

enum GFM {
    /// Parses `markdown` once; `repo` anchors bare references.
    static func blocks(_ markdown: String, repo: String, resolver: AutolinkResolver?) -> [GFMBlock] {
        let document = Document(parsing: markdown)
        return Converter(repo: repo, resolver: resolver).blocks(Array(document.children))
    }
}

private struct Converter {
    let repo: String
    let resolver: AutolinkResolver?

    // MARK: Blocks

    func blocks(_ nodes: [Markup]) -> [GFMBlock] {
        var output: [GFMBlock] = []
        // `<details>` opens in one HTML block and closes in a later one:
        // the blocks between them are its body.
        var open: [(summary: AttributedString, blocks: [GFMBlock])] = []
        func emit(_ block: GFMBlock) {
            if open.isEmpty { output.append(block) } else { open[open.count - 1].blocks.append(block) }
        }
        for node in nodes {
            if let html = node as? HTMLBlock {
                let raw = html.rawHTML
                if raw.range(of: "<details", options: .caseInsensitive) != nil {
                    open.append((AttributedString(Self.summary(raw) ?? "Details"), []))
                    let rest = Self.stripped(Self.removingSummary(raw))
                    if !rest.isEmpty { emit(.paragraph(AttributedString(rest))) }
                }
                for image in Self.images(raw) { emit(image) }
                if raw.range(of: "</details>", options: .caseInsensitive) != nil, let closing = open.popLast() {
                    emit(.details(summary: closing.summary, closing.blocks))
                }
                if raw.range(of: "<details", options: .caseInsensitive) == nil,
                   raw.range(of: "</details>", options: .caseInsensitive) == nil, Self.images(raw).isEmpty {
                    let text = Self.stripped(raw)
                    if !text.isEmpty { emit(.paragraph(AttributedString(text))) }
                }
                continue
            }
            for block in convert(node) { emit(block) }
        }
        // An unclosed `<details>` still shows its body.
        while let closing = open.popLast() {
            let block = GFMBlock.details(summary: closing.summary, closing.blocks)
            if open.isEmpty { output.append(block) } else { open[open.count - 1].blocks.append(block) }
        }
        return output
    }

    private func convert(_ node: Markup) -> [GFMBlock] {
        switch node {
        case let heading as Heading:
            return [.heading(heading.level, inline(heading))]
        case let paragraph as Paragraph:
            let parts = Array(paragraph.children).filter { !($0 is SoftBreak) && !($0 is LineBreak) }
            if !parts.isEmpty, parts.allSatisfy({ $0 is Image }) {
                return parts.compactMap { $0 as? Image }.map { .image($0.source.flatMap(URL.init(string:)), alt: $0.plainText) }
            }
            let text = inline(paragraph)
            return text.characters.isEmpty ? [] : [.paragraph(text)]
        case let quote as BlockQuote:
            let inner = blocks(Array(quote.children))
            if case let .paragraph(first)? = inner.first, let (alert, rest) = Self.alert(first) {
                let body = rest.characters.isEmpty ? Array(inner.dropFirst()) : [.paragraph(rest)] + inner.dropFirst()
                return [.alert(alert, body)]
            }
            return [.quote(inner)]
        case let code as CodeBlock:
            var text = code.code
            if text.hasSuffix("\n") { text.removeLast() }
            return [.code(language: code.language.flatMap { $0.isEmpty ? nil : $0 }, text)]
        case let list as UnorderedList:
            return [.list(ordered: false, start: 1, items: list.listItems.map(item))]
        case let list as OrderedList:
            return [.list(ordered: true, start: Int(list.startIndex), items: list.listItems.map(item))]
        case let table as Table:
            return [.table(self.table(table))]
        case is ThematicBreak:
            return [.rule]
        default:
            return blocks(Array(node.children))
        }
    }

    private func item(_ item: ListItem) -> GFMItem {
        let checked: Bool? = switch item.checkbox {
        case .checked: true
        case .unchecked: false
        case nil: nil
        }
        return GFMItem(checked: checked, blocks: blocks(Array(item.children)))
    }

    private func table(_ table: Table) -> GFMTable {
        let alignments: [GFMTable.Alignment] = table.columnAlignments.map {
            switch $0 {
            case .center: .center
            case .right: .trailing
            default: .leading
            }
        }
        return GFMTable(alignments: alignments,
                        header: Array(table.head.cells).map { inline($0) },
                        rows: Array(table.body.rows).map { row in Array(row.cells).map { inline($0) } })
    }

    // MARK: Inline

    func inline(_ container: Markup) -> AttributedString {
        var output = AttributedString()
        for child in container.children { output += inlineNode(child) }
        return output
    }

    private func inlineNode(_ node: Markup) -> AttributedString {
        switch node {
        case let text as Markdown.Text:
            return Autolink.linked(text.string, repo: repo, resolver: resolver)
        case let emphasis as Emphasis:
            return Self.adding(.emphasized, to: inline(emphasis))
        case let strong as Strong:
            return Self.adding(.stronglyEmphasized, to: inline(strong))
        case let strike as Strikethrough:
            return Self.adding(.strikethrough, to: inline(strike))
        case let code as InlineCode:
            var run = AttributedString(code.code)
            run.inlinePresentationIntent = .code
            return run
        case let link as Markdown.Link:
            var run = inline(link)
            if run.characters.isEmpty { run = AttributedString(link.destination ?? "") }
            if let destination = link.destination, let url = URL(string: destination) { run.link = url }
            return run
        case let image as Image:
            // An image among words reads as its alt text, linked to it.
            var run = AttributedString(image.plainText.isEmpty ? "image" : image.plainText)
            run.link = image.source.flatMap(URL.init(string:))
            return run
        case is SoftBreak:
            return AttributedString(" ")
        case is LineBreak:
            return AttributedString("\n")
        case let html as InlineHTML:
            return html.rawHTML.range(of: #"^<br\s*/?>$"#, options: [.regularExpression, .caseInsensitive]) != nil
                ? AttributedString("\n") : AttributedString()
        default:
            return inline(node)
        }
    }

    private static func adding(_ intent: InlinePresentationIntent, to text: AttributedString) -> AttributedString {
        var text = text
        for run in text.runs {
            text[run.range].inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(intent)
        }
        return text
    }

    // MARK: HTML and alerts

    /// `[!NOTE]` leading a quote's first paragraph → the alert and the rest.
    private static func alert(_ paragraph: AttributedString) -> (GFMAlert, AttributedString)? {
        let text = String(paragraph.characters)
        guard let match = text.range(of: #"^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*"#, options: .regularExpression),
              let alert = GFMAlert(rawValue: text[match].dropFirst(2).prefix { $0 != "]" }.lowercased())
        else { return nil }
        let start = paragraph.characters.index(paragraph.startIndex, offsetBy: text.distance(from: text.startIndex,
                                                                                             to: match.upperBound))
        return (alert, AttributedString(paragraph[start...]))
    }

    private static func summary(_ html: String) -> String? {
        guard let range = html.range(of: #"<summary[^>]*>[\s\S]*?</summary>"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        let summary = stripped(String(html[range]))
        return summary.isEmpty ? nil : summary
    }

    private static func removingSummary(_ html: String) -> String {
        html.replacingOccurrences(of: #"<summary[^>]*>[\s\S]*?</summary>"#, with: "",
                                  options: [.regularExpression, .caseInsensitive])
    }

    /// `<img src="…" alt="…">` → image blocks.
    private static func images(_ html: String) -> [GFMBlock] {
        let tag = try! NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: .caseInsensitive)
        return tag.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let range = Range(match.range, in: html) else { return nil }
            let element = String(html[range])
            return .image(attribute("src", in: element).flatMap(URL.init(string:)), alt: attribute("alt", in: element) ?? "")
        }
    }

    private static func attribute(_ name: String, in element: String) -> String? {
        guard let range = element.range(of: #"\b\#(name)\s*=\s*"[^"]*""#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        let value = element[range].drop { $0 != "\"" }.dropFirst().dropLast()
        return String(value)
    }

    /// Tags, comments and entities out; the text kept.
    static func stripped(_ html: String) -> String {
        html.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
