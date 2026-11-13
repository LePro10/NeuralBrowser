// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit

/// Small floating find-in-page bar (⌘F). Enter = next, Shift+Enter = previous, Esc = close.
@MainActor
final class FindBarView: NSVisualEffectView, NSSearchFieldDelegate {
    var onSearch: ((String, Bool) -> Void)?
    var onClose: (() -> Void)?

    private let field = NSSearchField()
    private let status = NSTextField(labelWithString: "")

    var query: String { field.stringValue }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 40))
        material = .popover
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 9
        field.placeholderString = "Find in page"
        field.delegate = self
        field.sendsSearchStringImmediately = false
        field.target = self
        field.action = #selector(search)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let prev = SidebarView.iconButton("chevron.up", "Previous")
        prev.target = self; prev.action = #selector(previous)
        let next = SidebarView.iconButton("chevron.down", "Next")
        next.target = self; next.action = #selector(nextMatch)
        let done = SidebarView.iconButton("xmark", "Done")
        done.target = self; done.action = #selector(close)
        let row = NSStackView(views: [field, status, prev, next, done])
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        row.frame = bounds
        row.autoresizingMask = [.width, .height]
        addSubview(row)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present(in parent: NSView) {
        if superview !== parent {
            frame.origin = NSPoint(x: parent.bounds.maxX - frame.width - 16, y: parent.bounds.maxY - frame.height - 12)
            autoresizingMask = [.minXMargin, .minYMargin]
            parent.addSubview(self, positioned: .above, relativeTo: nil)
        }
        window?.makeFirstResponder(field)
    }

    func setResult(found: Bool) {
        status.stringValue = found ? "" : "Not found"
    }

    @objc private func search() {
        let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        onSearch?(field.stringValue, backwards)
    }

    @objc private func previous() { onSearch?(field.stringValue, true) }
    @objc private func nextMatch() { onSearch?(field.stringValue, false) }

    @objc private func close() {
        removeFromSuperview()
        onClose?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            close()
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            search()
            return true
        }
        return false
    }
}
