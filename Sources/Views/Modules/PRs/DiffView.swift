import AppKit
import SwiftUI

/// A patch in an AppKit text surface (WP5): TextKit lays out hundreds of
/// lines without a SwiftUI view per line and wraps long ones under a fixed
/// gutter. Added lines wash `ok` with a `+`, removed lines `danger` with a
/// `−` (colour is never the only signal), hunk headers sit raised in `ink3`.
///
/// Read-only and never first responder: a text view holding focus would
/// take keys from the search field that `KeyboardCoordinator` routes through.
/// A long patch is `chunkSize`-line views, each a lazy item of the detail's
/// own scroller (`PRDetailContent`): a text view gets a backing store as tall
/// as itself, and every one that exists draws — a 1,500-line diff measured
/// ~400 MB when its chunks sat in a plain stack.
struct DiffView: NSViewRepresentable {
    static let chunkSize = 32

    let lines: [GitHubPRDetail.DiffLine]
    /// The gutter's figure width, shared by every chunk of one file so the
    /// columns line up; nil = this view's own widest number.
    var digits: Int?

    func makeNSView(context _: Context) -> DiffTextView {
        DiffTextView()
    }

    func updateNSView(_ view: DiffTextView, context _: Context) {
        view.show(lines, digits: digits ?? DiffTextView.digits(lines))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DiffTextView, context _: Context) -> CGSize? {
        let width = proposal.width ?? 640
        return CGSize(width: width, height: nsView.height(forWidth: width))
    }
}

final class DiffTextView: NSTextView {
    private var shown: (lines: [GitHubPRDetail.DiffLine], digits: Int)?

    init() {
        let storage = NSTextStorage()
        let layout = DiffLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 6
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = false
        drawsBackground = false
        isVerticallyResizable = false
        isHorizontallyResizable = false
        textContainerInset = .zero
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("DiffTextView is built in code")
    }

    override var acceptsFirstResponder: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        textContainer?.containerSize = NSSize(width: newSize.width, height: .greatestFiniteMagnitude)
    }

    func show(_ lines: [GitHubPRDetail.DiffLine], digits: Int) {
        if let shown, shown.lines == lines, shown.digits == digits { return }
        shown = (lines, digits)
        textStorage?.setAttributedString(Self.render(lines, digits: digits))
    }

    /// The widest line number, at least three figures.
    static func digits(_ lines: [GitHubPRDetail.DiffLine]) -> Int {
        max(3, String(lines.compactMap { max($0.old ?? 0, $0.new ?? 0) }.max() ?? 0).count)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard let container = textContainer, let layout = layoutManager else { return 0 }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height + textContainerInset.height * 2)
    }

    // MARK: - Rendering

    private static let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    private static let ink = NSColor(Theme.ink)
    private static let ink2 = NSColor(Theme.ink2)
    private static let ink3 = NSColor(Theme.ink3)
    private static let ok = NSColor(Theme.ok)
    private static let danger = NSColor(Theme.danger)

    static func render(_ lines: [GitHubPRDetail.DiffLine], digits: Int) -> NSAttributedString {
        let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
        // "old new ± " — wrapped continuations start under the code, not the gutter.
        let gutter = digits * 2 + 4
        let paragraph = NSMutableParagraphStyle()
        paragraph.headIndent = CGFloat(gutter) * advance
        paragraph.lineHeightMultiple = 1.15
        paragraph.lineBreakMode = .byCharWrapping

        let text = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            let number: (Int?) -> String = { value in
                let figure = value.map(String.init) ?? ""
                return String(repeating: " ", count: max(0, digits - figure.count)) + figure
            }
            let marker: String
            let markerColor: NSColor
            let textColor: NSColor
            let wash: NSColor?
            switch line.kind {
            case .added: (marker, markerColor, textColor, wash) = ("+", ok, ink, ok.withAlphaComponent(0.12))
            case .removed: (marker, markerColor, textColor, wash) = ("−", danger, ink, danger.withAlphaComponent(0.12))
            case .hunk: (marker, markerColor, textColor, wash) = (" ", ink3, ink3, NSColor.white.withAlphaComponent(0.04))
            case .note: (marker, markerColor, textColor, wash) = (" ", ink3, ink3, nil)
            case .context: (marker, markerColor, textColor, wash) = (" ", ink3, ink2, nil)
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
            if let wash { attributes[.diffWash] = wash }
            let start = text.length
            text.append(NSAttributedString(string: "\(number(line.old)) \(number(line.new)) ",
                                           attributes: attributes.merging([.foregroundColor: ink3]) { $1 }))
            text.append(NSAttributedString(string: "\(marker) ",
                                           attributes: attributes.merging([.foregroundColor: markerColor]) { $1 }))
            let body = index == lines.count - 1 ? line.text : line.text + "\n"
            text.append(NSAttributedString(string: body,
                                           attributes: attributes.merging([.foregroundColor: textColor]) { $1 }))
            if wash == nil { text.removeAttribute(.diffWash, range: NSRange(location: start, length: text.length - start)) }
        }
        return text
    }
}

extension NSAttributedString.Key {
    /// A diff line's full-width wash, painted by `DiffLayoutManager`.
    static let diffWash = NSAttributedString.Key("pultik.diffWash")
}

/// Paints each washed line across the whole container width — a plain
/// `.backgroundColor` stops where the glyphs do.
final class DiffLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        enumerateLineFragments(forGlyphRange: glyphsToShow) { rect, _, _, glyphRange, _ in
            let index = self.characterIndexForGlyph(at: glyphRange.location)
            guard index < storage.length,
                  let wash = storage.attribute(.diffWash, at: index, effectiveRange: nil) as? NSColor else { return }
            wash.setFill()
            NSBezierPath(rect: NSRect(x: origin.x, y: rect.minY + origin.y,
                                      width: container.size.width, height: rect.height)).fill()
        }
    }
}
