import SwiftUI
import UIKit

/// A code editor backed by UITextView: monospaced, no autocorrection, Swift colouring, auto-indent,
/// small line numbers and marked error lines.
struct CodeEditor: UIViewRepresentable {
    @Binding var text: String
    var highlightsSwift: Bool
    /// 1-based line → error message.
    var errorLines: [Int: String] = [:]
    /// Set to a line number to scroll there and put the cursor on it.
    @Binding var focusLine: Int?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> LineNumberTextView {
        let textView = LineNumberTextView()
        textView.font = SwiftHighlighter.font
        textView.backgroundColor = .systemBackground
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.keyboardDismissMode = .interactive
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 12, left: LineNumberTextView.gutterWidth + 6, bottom: 40, right: 8)
        textView.delegate = context.coordinator
        textView.inputAccessoryView = context.coordinator.makeAccessoryBar()
        textView.text = text
        textView.textDidChange()
        textView.errorLines = errorLines
        context.coordinator.textView = textView
        context.coordinator.applyHighlighting()
        return textView
    }

    func updateUIView(_ textView: LineNumberTextView, context: Context) {
        context.coordinator.parent = self
        if textView.text != text {
            textView.text = text
            textView.textDidChange()
            context.coordinator.applyHighlighting()
        }
        textView.errorLines = errorLines
        if let line = focusLine {
            DispatchQueue.main.async {
                context.coordinator.focus(line: line)
                focusLine = nil
            }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeEditor
        weak var textView: LineNumberTextView?
        private let highlighter = SwiftHighlighter()

        init(parent: CodeEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            self.textView?.textDidChange()
            applyHighlighting()
        }

        func focus(line: Int) {
            guard let textView, let range = textView.characterRange(ofLine: line) else { return }
            textView.becomeFirstResponder()
            textView.selectedRange = NSRange(location: range.location, length: 0)
            textView.scrollRangeToVisible(range)
        }

        func applyHighlighting() {
            guard let textView else { return }
            if parent.highlightsSwift {
                highlighter.highlight(textView.textStorage)
            }
            textView.typingAttributes = [.font: SwiftHighlighter.font, .foregroundColor: UIColor.label]
        }

        /// Keeps the indentation of the current line on a new line, and indents after `{`.
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
            guard replacement == "\n" else { return true }
            let text = textView.text as NSString
            let lineRange = text.lineRange(for: NSRange(location: range.location, length: 0))
            let lineUpToCursor = text.substring(with: NSRange(location: lineRange.location, length: range.location - lineRange.location))
            var indentation = String(lineUpToCursor.prefix { $0 == " " || $0 == "\t" })
            if lineUpToCursor.trimmingCharacters(in: .whitespaces).hasSuffix("{") {
                indentation += "    "
            }
            insert("\n" + indentation, in: textView)
            return false
        }

        private func insert(_ string: String, in textView: UITextView) {
            textView.insertText(string)
        }

        func makeAccessoryBar() -> UIView {
            let symbols = ["⇥", "{", "}", "(", ")", "[", "]", "\"", ".", ":", "=", "\\", "$", "@"]
            let stack = UIStackView()
            stack.axis = .horizontal
            stack.spacing = 6
            stack.translatesAutoresizingMaskIntoConstraints = false
            for symbol in symbols {
                var configuration = UIButton.Configuration.gray()
                configuration.title = symbol
                configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
                let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
                    guard let self, let textView = self.textView else { return }
                    self.insert(symbol == "⇥" ? "    " : symbol, in: textView)
                })
                stack.addArrangedSubview(button)
            }
            var doneConfiguration = UIButton.Configuration.plain()
            doneConfiguration.image = UIImage(systemName: "keyboard.chevron.compact.down")
            stack.addArrangedSubview(UIButton(configuration: doneConfiguration, primaryAction: UIAction { [weak self] _ in
                self?.textView?.resignFirstResponder()
            }))

            let scroll = UIScrollView()
            scroll.showsHorizontalScrollIndicator = false
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.addSubview(stack)

            let bar = UIInputView(frame: CGRect(x: 0, y: 0, width: 320, height: 48), inputViewStyle: .keyboard)
            bar.addSubview(scroll)
            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
                scroll.topAnchor.constraint(equalTo: bar.topAnchor),
                scroll.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
                stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
                stack.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            ])
            return bar
        }
    }
}
