import AppKit
import EdgeGesture

final class SettingsWindow: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    var onToggle: (Bool) -> Void = { _ in }
    var onSensitivity: (Float) -> Void = { _ in }
    var onAssignment: (EdgeAssignment) -> Void = { _ in }
    var onShowHud: (Bool) -> Void = { _ in }
    var onHideDelay: (Int) -> Void = { _ in }

    private let window: NSWindow
    private let toggle = NSSwitch()
    private let hudToggle = NSSwitch()
    private let slider = NSSlider()
    private let delayField = NSTextField(frame: .zero)
    private var hideDelay = 400
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let rightPicker = ActionPicker(frame: .zero)
    private let leftPicker = ActionPicker(frame: .zero)
    private let bottomPicker = ActionPicker(frame: .zero)
    private var updating = false

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Trackpad"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Palette.canvas
        window.delegate = self

        toggle.target = self
        toggle.action = #selector(toggled)
        hudToggle.target = self
        hudToggle.action = #selector(hudToggled)
        slider.minValue = 0.2
        slider.maxValue = 1
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(slid)
        delayField.alignment = .right
        delayField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        delayField.textColor = .white
        delayField.backgroundColor = NSColor.white.withAlphaComponent(0.08)
        delayField.isBezeled = true
        delayField.bezelStyle = .roundedBezel
        delayField.delegate = self
        delayField.target = self
        delayField.action = #selector(delayEdited)
        delayField.translatesAutoresizingMaskIntoConstraints = false
        delayField.widthAnchor.constraint(equalToConstant: 72).isActive = true
        rightPicker.onChange = { [weak self] _ in self?.assignmentChanged() }
        leftPicker.onChange = { [weak self] _ in self?.assignmentChanged() }
        bottomPicker.onChange = { [weak self] _ in self?.assignmentChanged() }

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.preferredMaxLayoutWidth = 580
        statusLabel.isHidden = true

        let stack = NSStackView(frame: .zero)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.detachesHiddenViews = true

        let title = label("Trackpad", size: 22, weight: .semibold, color: .white)
        let subtitle = wrapping(
            "Rest one finger on the trackpad edge and slide it along. With two or more fingers your trackpad works as always."
        )
        subtitle.preferredMaxLayoutWidth = 580

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(subtitle)
        stack.setCustomSpacing(6, after: title)

        stack.addArrangedSubview(card(onRow()))
        let edgesHeader = section("EDGES")
        stack.addArrangedSubview(edgesHeader)
        stack.setCustomSpacing(8, after: edgesHeader)
        stack.addArrangedSubview(edgesCard())
        let responseHeader = section("RESPONSE")
        stack.addArrangedSubview(responseHeader)
        stack.setCustomSpacing(8, after: responseHeader)
        stack.addArrangedSubview(responseCard())
        stack.addArrangedSubview(statusLabel)

        stretch(stack.arrangedSubviews[2], in: stack)
        stretch(stack.arrangedSubviews[4], in: stack)
        stretch(stack.arrangedSubviews[6], in: stack)
        stretch(statusLabel, in: stack)

        let content = NSView(frame: .zero)
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 46),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
        ])
        window.contentView = content
        window.center()
    }

    func show(
        enabled: Bool,
        sensitivity: Float,
        assignment: EdgeAssignment,
        showHud: Bool,
        hideDelay: Int,
        status: String,
        statusIsError: Bool
    ) {
        apply(
            enabled: enabled,
            sensitivity: sensitivity,
            assignment: assignment,
            showHud: showHud,
            hideDelay: hideDelay,
            status: status,
            statusIsError: statusIsError
        )
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func apply(
        enabled: Bool,
        sensitivity: Float,
        assignment: EdgeAssignment,
        showHud: Bool,
        hideDelay: Int,
        status: String,
        statusIsError: Bool
    ) {
        updating = true
        self.hideDelay = hideDelay
        toggle.state = enabled ? .on : .off
        hudToggle.state = showHud ? .on : .off
        slider.doubleValue = Double(sensitivity)
        delayField.stringValue = String(hideDelay)
        rightPicker.setSelected(assignment.right)
        leftPicker.setSelected(assignment.left)
        bottomPicker.setSelected(assignment.bottom)
        statusLabel.stringValue = status
        statusLabel.textColor = statusIsError ? .systemRed : Palette.secondary
        statusLabel.isHidden = !statusIsError
        updating = false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    @objc private func toggled() {
        guard !updating else { return }
        onToggle(toggle.state == .on)
    }

    @objc private func hudToggled() {
        guard !updating else { return }
        onShowHud(hudToggle.state == .on)
    }

    @objc private func slid() {
        guard !updating else { return }
        onSensitivity(Float(slider.doubleValue))
    }

    @objc private func delayEdited() {
        commitDelay()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitDelay()
    }

    private func commitDelay() {
        guard !updating else { return }
        let parsed = Int(delayField.stringValue.trimmingCharacters(in: .whitespaces))
        let value = min(5000, max(0, parsed ?? hideDelay))
        hideDelay = value
        delayField.stringValue = String(value)
        onHideDelay(value)
    }

    private func assignmentChanged() {
        guard !updating else { return }
        onAssignment(EdgeAssignment(
            left: leftPicker.selected,
            right: rightPicker.selected,
            bottom: bottomPicker.selected
        ))
    }

    private func onRow() -> NSView {
        let row = NSStackView(frame: .zero)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        let spacer = NSView(frame: .zero)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(label("On", size: 13, weight: .medium, color: .white))
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(toggle)
        return row
    }

    private func edgesCard() -> NSView {
        let rows = NSStackView(frame: .zero)
        rows.orientation = .vertical
        rows.spacing = 0
        let right = edgeRow(title: "Right edge", detail: "Up and down", picker: rightPicker)
        let left = edgeRow(title: "Left edge", detail: "Up and down", picker: leftPicker)
        let bottom = edgeRow(title: "Bottom edge", detail: "Left and right", picker: bottomPicker)
        let line1 = hairline()
        let line2 = hairline()
        rows.addArrangedSubview(right)
        rows.addArrangedSubview(line1)
        rows.addArrangedSubview(left)
        rows.addArrangedSubview(line2)
        rows.addArrangedSubview(bottom)
        for item in [right, left, bottom, line1, line2] {
            item.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        return card(rows)
    }

    private func edgeRow(title: String, detail: String, picker: ActionPicker) -> NSView {
        let row = NSStackView(frame: .zero)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        let names = NSStackView(frame: .zero)
        names.orientation = .vertical
        names.alignment = .leading
        names.spacing = 1
        names.addArrangedSubview(label(title, size: 13, weight: .semibold, color: .white))
        names.addArrangedSubview(label(detail, size: 11, weight: .regular, color: Palette.secondary))
        let spacer = NSView(frame: .zero)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(names)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(picker)
        return row
    }

    private func responseCard() -> NSView {
        let rows = NSStackView(frame: .zero)
        rows.orientation = .vertical
        rows.spacing = 0

        let sensitivity = NSStackView(frame: .zero)
        sensitivity.orientation = .horizontal
        sensitivity.alignment = .centerY
        sensitivity.edgeInsets = NSEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        let spacer = NSView(frame: .zero)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 210).isActive = true
        sensitivity.addArrangedSubview(label("Sensitivity", size: 13, weight: .medium, color: .white))
        sensitivity.addArrangedSubview(spacer)
        sensitivity.addArrangedSubview(slider)

        let notch = NSStackView(frame: .zero)
        notch.orientation = .horizontal
        notch.alignment = .centerY
        notch.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        let spacer2 = NSView(frame: .zero)
        spacer2.setContentHuggingPriority(.defaultLow, for: .horizontal)
        notch.addArrangedSubview(label("Show the level in the notch", size: 13, weight: .medium, color: .white))
        notch.addArrangedSubview(spacer2)
        notch.addArrangedSubview(hudToggle)

        let delay = NSStackView(frame: .zero)
        delay.orientation = .horizontal
        delay.alignment = .centerY
        delay.spacing = 8
        delay.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 10, right: 8)
        let spacer3 = NSView(frame: .zero)
        spacer3.setContentHuggingPriority(.defaultLow, for: .horizontal)
        delay.addArrangedSubview(label("Hide delay", size: 13, weight: .medium, color: .white))
        delay.addArrangedSubview(spacer3)
        delay.addArrangedSubview(delayField)
        delay.addArrangedSubview(label("ms", size: 13, weight: .medium, color: Palette.secondary))

        let line = hairline()
        let line2 = hairline()
        rows.addArrangedSubview(sensitivity)
        rows.addArrangedSubview(line)
        rows.addArrangedSubview(notch)
        rows.addArrangedSubview(line2)
        rows.addArrangedSubview(delay)
        for item in [sensitivity, line, notch, line2, delay] {
            item.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        return card(rows)
    }

    private func card(_ content: NSView) -> NSView {
        let box = NSView(frame: .zero)
        box.wantsLayer = true
        box.layer?.backgroundColor = Palette.card.cgColor
        box.layer?.cornerRadius = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: box.topAnchor),
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        return box
    }

    private func section(_ text: String) -> NSTextField {
        let field = label(text, size: 11, weight: .semibold, color: Palette.secondary)
        return field
    }

    private func hairline() -> NSView {
        let wrap = NSView(frame: .zero)
        let line = NSView(frame: .zero)
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 16),
            line.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -16),
            line.topAnchor.constraint(equalTo: wrap.topAnchor),
            line.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
            wrap.heightAnchor.constraint(equalToConstant: 1),
        ])
        return wrap
    }

    private func stretch(_ view: NSView, in stack: NSStackView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }

    private func wrapping(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 13)
        field.textColor = Palette.secondary
        return field
    }
}

private enum Palette {
    static let canvas = NSColor(srgbRed: 0.09, green: 0.10, blue: 0.13, alpha: 1)
    static let card = NSColor(srgbRed: 0.15, green: 0.16, blue: 0.20, alpha: 1)
    static let secondary = NSColor(white: 0.62, alpha: 1)
    static let selected = NSColor(srgbRed: 0.33, green: 0.48, blue: 0.95, alpha: 1)
}

private final class ActionPicker: NSStackView {
    var onChange: (EdgeAction) -> Void = { _ in }
    private(set) var selected: EdgeAction = .nothing
    private var buttons: [EdgeAction: NSButton] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        orientation = .horizontal
        spacing = 2
        alignment = .centerY
        for action in [EdgeAction.volume, .brightness, .tracks, .nothing] {
            let button = NSButton()
            button.setButtonType(.momentaryPushIn)
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 9
            button.target = self
            button.action = #selector(picked(_:))
            button.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 84).isActive = true
            button.heightAnchor.constraint(equalToConstant: 26).isActive = true
            buttons[action] = button
            addArrangedSubview(button)
        }
        setSelected(.nothing)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSelected(_ action: EdgeAction) {
        selected = action
        for (item, button) in buttons {
            let on = item == action
            button.layer?.backgroundColor = (on ? Palette.selected : NSColor.clear).cgColor
            let title = item.rawValue.prefix(1).uppercased() + item.rawValue.dropFirst()
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: on ? NSColor.white : Palette.secondary,
                .font: NSFont.systemFont(ofSize: 12, weight: on ? .semibold : .medium),
            ])
        }
    }

    @objc private func picked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let action = EdgeAction(rawValue: raw) else { return }
        setSelected(action)
        onChange(action)
    }
}
