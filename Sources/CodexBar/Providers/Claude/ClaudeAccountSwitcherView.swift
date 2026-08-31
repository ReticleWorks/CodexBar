import AppKit
import CodexBarCore

/// Provider-neutral account selector used by Claude's menu presentation.
/// Display selection is local to the menu; this view never activates a
/// credential, even when an option can be activated by its source.
final class ClaudeSwapAccountSwitcherView: NSView {
    private let options: [ProviderAccountUsageSnapshot]
    private let onSelect: (ProviderAccountUsageSnapshot) -> Void
    private var selectedAccountID: ProviderAccountIdentity
    private var pressedAccountID: ProviderAccountIdentity?
    private var buttons: [NSButton] = []
    private let preferredSize: NSSize
    private let rowSpacing: CGFloat = 4
    private let rowHeight: CGFloat = 26
    private let selectedBackground: CGColor
    private let unselectedBackground = NSColor.clear.cgColor
    private let selectedTextColor: NSColor
    private let unselectedTextColor = NSColor.secondaryLabelColor
    private let buttonFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    private let buttonSideInset: CGFloat = 6

    init(
        options: [ProviderAccountUsageSnapshot],
        selectedAccountID: ProviderAccountIdentity?,
        width: CGFloat,
        accentColor: NSColor = .controlAccentColor,
        onSelect: @escaping (ProviderAccountUsageSnapshot) -> Void)
    {
        self.options = options
        self.onSelect = onSelect
        self.selectedAccountID = selectedAccountID ?? options.first?.id ??
            ProviderAccountIdentity(source: "none", opaqueID: "none")
        self.selectedBackground = accentColor.cgColor
        self.selectedTextColor = Self.contrastingTextColor(for: accentColor)
        let useTwoRows = options.count > 3
        let rows = useTwoRows ? 2 : 1
        let height = self.rowHeight * CGFloat(rows) + (useTwoRows ? self.rowSpacing : 0)
        self.preferredSize = NSSize(width: width, height: height)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        self.wantsLayer = true
        self.buildButtons(useTwoRows: useTwoRows)
        self.updateButtonStyles()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        self.preferredSize
    }

    override var fittingSize: NSSize {
        self.preferredSize
    }

    private func buildButtons(useTwoRows: Bool) {
        let perRow = useTwoRows ? Int(ceil(Double(self.options.count) / 2.0)) : self.options.count
        let rows: [[ProviderAccountUsageSnapshot]] = {
            if !useTwoRows { return [self.options] }
            return [
                Array(self.options.prefix(perRow)),
                Array(self.options.dropFirst(perRow)),
            ]
        }()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = self.rowSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        for rowOptions in rows {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.distribution = .fillEqually
            row.spacing = self.rowSpacing
            row.translatesAutoresizingMaskIntoConstraints = false
            let buttonWidth = self.buttonWidth(for: rowOptions.count)
            for option in rowOptions {
                let button = PaddedToggleButton(
                    title: self.compactTitle(option.displayLabel, buttonWidth: buttonWidth),
                    target: self,
                    action: #selector(self.handleSelect))
                button.identifier = NSUserInterfaceItemIdentifier(self.identifier(for: option.id))
                let message = option.error?.trimmingCharacters(in: .whitespacesAndNewlines)
                button.toolTip = message.map { "\(option.displayLabel) — \($0)" } ?? option.displayLabel
                button.isBordered = false
                button.setButtonType(.toggle)
                button.controlSize = .small
                button.font = self.buttonFont
                button.cell?.lineBreakMode = .byTruncatingTail
                button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                button.wantsLayer = true
                button.layer?.cornerRadius = 6
                if self.options.count == 3 {
                    button.contentPadding.left = 4
                    button.contentPadding.right = 4
                }
                row.addArrangedSubview(button)
                self.buttons.append(button)
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        self.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: self.buttonSideInset),
            stack.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -self.buttonSideInset),
            stack.topAnchor.constraint(equalTo: self.topAnchor),
            stack.bottomAnchor.constraint(equalTo: self.bottomAnchor),
            stack.heightAnchor.constraint(equalToConstant: self.rowHeight * CGFloat(rows.count) +
                (useTwoRows ? self.rowSpacing : 0)),
        ])
    }

    private func buttonWidth(for count: Int) -> CGFloat {
        let contentWidth = self.bounds.width - (self.buttonSideInset * 2)
        let spacing = self.rowSpacing * CGFloat(max(0, count - 1))
        guard count > 0 else { return contentWidth }
        return max(44, floor((contentWidth - spacing) / CGFloat(count)))
    }

    private func compactTitle(_ title: String, buttonWidth: CGFloat) -> String {
        let available = max(24, buttonWidth - (self.options.count == 3 ? 8 : 14))
        guard self.textWidth(title) > available else { return title }
        return self.truncateMiddle(title, toFit: available)
    }

    private func textWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: self.buttonFont]).width)
    }

    private func truncateMiddle(_ text: String, toFit width: CGFloat) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, self.textWidth(trimmed) > width else { return trimmed }
        let ellipsis = "…"
        guard self.textWidth(ellipsis) < width else { return ellipsis }
        var prefix = ""
        var suffix = ""
        var prefixIndex = trimmed.startIndex
        var suffixIndex = trimmed.endIndex
        var takeSuffix = true
        var best = ellipsis
        while prefixIndex < suffixIndex {
            if takeSuffix {
                let index = trimmed.index(before: suffixIndex)
                let candidate = prefix + ellipsis + String(trimmed[index]) + suffix
                guard self.textWidth(candidate) <= width else { break }
                suffixIndex = index
                suffix = String(trimmed[index]) + suffix
            } else {
                let candidate = prefix + String(trimmed[prefixIndex]) + ellipsis + suffix
                guard self.textWidth(candidate) <= width else { break }
                prefix = prefix + String(trimmed[prefixIndex])
                prefixIndex = trimmed.index(after: prefixIndex)
            }
            best = prefix + ellipsis + suffix
            takeSuffix.toggle()
        }
        return best
    }

    private func updateButtonStyles() {
        for button in self.buttons {
            let selected = self.options.first {
                self.identifier(for: $0.id) == button.identifier?.rawValue
            }?.id == self.selectedAccountID
            button.state = selected ? .on : .off
            button.layer?.backgroundColor = selected ? self.selectedBackground : self.unselectedBackground
            button.contentTintColor = selected ? self.selectedTextColor : self.unselectedTextColor
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let descendant = super.hitTest(point)
        if descendant != nil, descendant !== self {
            self.toolTip = (descendant as? NSButton)?.toolTip
            return self
        }
        self.toolTip = nil
        return descendant
    }

    override func mouseDown(with event: NSEvent) {
        let point = self.convert(event.locationInWindow, from: nil)
        self.pressedAccountID = self.optionID(at: point)
    }

    override func mouseUp(with event: NSEvent) {
        defer { self.pressedAccountID = nil }
        guard let pressedAccountID = self.pressedAccountID else { return }
        let point = self.convert(event.locationInWindow, from: nil)
        guard self.optionID(at: point) == pressedAccountID,
              let option = self.options.first(where: { $0.id == pressedAccountID })
        else { return }
        self.applySelection(option)
    }

    @objc private func handleSelect(_ sender: NSButton) {
        guard let rawID = sender.identifier?.rawValue,
              let option = self.options.first(where: { self.identifier(for: $0.id) == rawID })
        else { return }
        self.applySelection(option)
    }

    private func optionID(at point: NSPoint) -> ProviderAccountIdentity? {
        self.buttons.first {
            self.convert($0.bounds, from: $0).contains(point)
        }.flatMap { button in
            guard let rawID = button.identifier?.rawValue else { return nil }
            return self.options.first(where: { self.identifier(for: $0.id) == rawID })?.id
        }
    }

    private func applySelection(_ option: ProviderAccountUsageSnapshot) {
        self.selectedAccountID = option.id
        self.updateButtonStyles()
        self.onSelect(option)
    }

    private func identifier(for id: ProviderAccountIdentity) -> String {
        "\(id.source):\(id.opaqueID)"
    }

    private static func contrastingTextColor(for background: NSColor) -> NSColor {
        guard let rgb = background.usingColorSpace(.deviceRGB) else { return .white }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance > 0.62 ? NSColor(deviceWhite: 0.08, alpha: 1) : .white
    }
}
