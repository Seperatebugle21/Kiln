import UIKit

/// A UITextView with a narrow gutter of small line numbers on the left. Lines with an error get a
/// red number and a soft red band across the line.
final class LineNumberTextView: UITextView {
    static let gutterWidth: CGFloat = 30

    /// Line number (1-based) → message, for lines with an error.
    var errorLines: [Int: String] = [:] {
        didSet {
            guard errorLines != oldValue else { return }
            gutter.setNeedsDisplay()
            errorBands.setNeedsDisplay()
        }
    }

    private let gutter = GutterView()
    private let errorBands = ErrorBandView()
    /// Character offsets where each line starts, for fast line-number lookups.
    private var lineStarts: [Int] = [0]

    init() {
        // TextKit 1, for the line fragment geometry the gutter needs.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        gutter.owner = self
        errorBands.owner = self
        gutter.isUserInteractionEnabled = false
        errorBands.isUserInteractionEnabled = false
        insertSubview(errorBands, at: 0)
        addSubview(gutter)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Call after the text changes.
    func textDidChange() {
        let text = self.text as NSString? ?? ""
        var starts = [0]
        var index = 0
        while index < text.length {
            let range = text.range(of: "\n", options: [], range: NSRange(location: index, length: text.length - index))
            guard range.location != NSNotFound else { break }
            starts.append(range.location + 1)
            index = range.location + 1
        }
        lineStarts = starts
        gutter.setNeedsDisplay()
        errorBands.setNeedsDisplay()
    }

    /// Both overlays cover only the visible area and redraw as it scrolls, so long files stay cheap.
    override func layoutSubviews() {
        super.layoutSubviews()
        let visible = CGRect(origin: contentOffset, size: bounds.size)
        if gutter.frame != CGRect(x: visible.minX, y: visible.minY, width: Self.gutterWidth, height: visible.height) {
            gutter.frame = CGRect(x: visible.minX, y: visible.minY, width: Self.gutterWidth, height: visible.height)
            errorBands.frame = visible
        }
        gutter.setNeedsDisplay()
        errorBands.setNeedsDisplay()
        bringSubviewToFront(gutter)
    }

    /// The 1-based line that a character offset is on.
    func lineNumber(atCharacter offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    /// The character range of a 1-based line.
    func characterRange(ofLine line: Int) -> NSRange? {
        guard line >= 1, line <= lineStarts.count else { return nil }
        let start = lineStarts[line - 1]
        let end = line < lineStarts.count ? lineStarts[line] : (text as NSString? ?? "").length
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Calls `body` with each visible line fragment that starts a line: its line number and rect
    /// (in the text view's coordinates).
    fileprivate func forEachLineStart(in rect: CGRect, _ body: (Int, CGRect) -> Void) {
        let inset = textContainerInset
        // Only the vertical extent matters: the gutter itself lies left of the text, so ask for the
        // lines across the whole width of the text container.
        let visible = CGRect(x: 0, y: rect.minY - inset.top, width: max(textContainer.size.width, 1), height: rect.height)
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: textContainer)
        let text = self.text as NSString? ?? ""
        var found: [(Int, CGRect)] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, glyphRange, _ in
            let characterIndex = self.layoutManager.characterIndexForGlyph(at: glyphRange.location)
            let isLineStart = characterIndex == 0 || (characterIndex <= text.length && text.character(at: characterIndex - 1) == 10)
            guard isLineStart else { return }
            found.append((self.lineNumber(atCharacter: characterIndex), fragment.offsetBy(dx: inset.left, dy: inset.top)))
        }
        for (line, frame) in found {
            body(line, frame)
        }
        // The empty last line after a trailing newline has no fragment of its own.
        if text.length == 0 || text.character(at: text.length - 1) == 10 {
            let extra = layoutManager.extraLineFragmentRect
            if extra.height > 0 {
                let frame = extra.offsetBy(dx: inset.left, dy: inset.top)
                if frame.intersects(rect) { body(lineStarts.count, frame) }
            }
        }
    }

    // MARK: Views

    private final class GutterView: UIView {
        weak var owner: LineNumberTextView?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = false
            contentMode = .redraw
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func draw(_ rect: CGRect) {
            guard let owner else { return }
            UIColor.systemBackground.setFill()
            UIRectFill(rect)
            UIColor.separator.withAlphaComponent(0.4).setFill()
            UIRectFill(CGRect(x: bounds.width - 0.5, y: rect.minY, width: 0.5, height: rect.height))

            let font = UIFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .right
            let origin = frame.origin
            owner.forEachLineStart(in: rect.offsetBy(dx: origin.x, dy: origin.y)) { line, textFragment in
                let fragment = textFragment.offsetBy(dx: -origin.x, dy: -origin.y)
                let isError = owner.errorLines[line] != nil
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: isError ? UIFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold) : font,
                    .foregroundColor: isError ? UIColor.systemRed : UIColor.tertiaryLabel,
                    .paragraphStyle: paragraph,
                ]
                let textHeight = font.lineHeight
                let y = fragment.minY + (fragment.height - textHeight) / 2
                if isError {
                    UIColor.systemRed.setFill()
                    UIBezierPath(roundedRect: CGRect(x: 2, y: fragment.minY + 2, width: 3, height: fragment.height - 4), cornerRadius: 1.5).fill()
                }
                ("\(line)" as NSString).draw(in: CGRect(x: 0, y: y, width: bounds.width - 5, height: textHeight), withAttributes: attributes)
            }
        }
    }

    private final class ErrorBandView: UIView {
        weak var owner: LineNumberTextView?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = false
            backgroundColor = .clear
            contentMode = .redraw
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func draw(_ rect: CGRect) {
            guard let owner, !owner.errorLines.isEmpty else { return }
            UIColor.systemRed.withAlphaComponent(0.12).setFill()
            let origin = frame.origin
            owner.forEachLineStart(in: rect.offsetBy(dx: origin.x, dy: origin.y)) { line, textFragment in
                guard owner.errorLines[line] != nil else { return }
                let fragment = textFragment.offsetBy(dx: -origin.x, dy: -origin.y)
                UIRectFill(CGRect(x: 0, y: fragment.minY, width: bounds.width, height: fragment.height))
            }
        }
    }
}
