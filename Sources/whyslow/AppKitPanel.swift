import AppKit
import Combine
import ServiceManagement

// The menu bar panel, drawn with AppKit: an empty SwiftUI menu bar app needs 16 MB, an AppKit one 12 MB.
@MainActor
final class AppKitPanel: NSObject {
    let model: Model
    var forceOpen = false
    private let item: NSStatusItem?
    private let panel = Panel()
    private var watch: AnyCancellable?
    private var openedAt = Date()
    private var showMore = false
    private var showLeftovers = false
    private var targets: [Target] = []
    private var renderQueued = false
    private var animateNext = false

    init(model: Model, statusItem: Bool = true) {
        self.model = model
        item = statusItem ? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength) : nil
        super.init()
        item?.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "whyslow")
        item?.button?.target = self
        item?.button?.action = #selector(toggle)
        // A check changes several published properties at once; build the view tree once per run-loop turn.
        watch = model.objectWillChange.sink { [weak self] in
            guard let self, !self.renderQueued else { return }
            self.renderQueued = true
            DispatchQueue.main.async { self.renderQueued = false; self.render() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    // While closed, the panel keeps no views: they are rebuilt in a few ms on open, and the free pages go back to macOS.
    func close() {
        panel.orderOut(nil)
        panel.contentView?.subviews = []
        targets = []
        malloc_zone_pressure_relief(nil, 0)
    }

    @objc func toggle() {
        if panel.isVisible { return close() }
        openedAt = Date()
        if model.snap.map({ openedAt.timeIntervalSince($0.now) > 10 }) ?? true { model.refresh() }
        render()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    private func render() {
        guard panel.isVisible || item == nil, let glass = panel.contentView else { return }
        var view = NSView()
        panel.effectiveAppearance.performAsCurrentDrawingAppearance { view = content() }
        glass.subviews = [view]
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: glass.leadingAnchor), view.topAnchor.constraint(equalTo: glass.topAnchor)])
        let size = view.fittingSize
        guard let button = item?.button, let window = button.window, let screen = window.screen else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let x = min(max(anchor.minX - 8, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
        let frame = NSRect(x: x, y: anchor.minY - 6 - size.height, width: size.width, height: size.height)
        guard animateNext else { return panel.setFrame(frame, display: true) }
        animateNext = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    func content() -> NSView {
        targets = []
        let main = model.found.filter { $0.bucket != .leftovers }
        let left = model.found.filter { $0.bucket == .leftovers }
        let root = column(spacing: 12)
        root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        root.widthAnchor.constraint(equalToConstant: 400).isActive = true

        if let s = model.snap {
            let v = verdict(s, model.found)
            let words = column(spacing: 2, [label(v.headline, .preferredFont(forTextStyle: .headline))])
            if let c = v.cause { words.addArrangedSubview(label(c, .preferredFont(forTextStyle: .subheadline), .secondaryLabelColor)) }
            root.addArrangedSubview(row(spacing: 10, align: .top, [
                lineHigh(symbol(v.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill", .title2, v.ok ? .systemGreen : .systemOrange), height: 19),
                words,
            ]))
            root.addArrangedSubview(row(spacing: 6, [
                chip("memorychip", ["Memory OK", "Memory OK", "Memory tight", "Memory tight", "Memory full"][Int(min(max(s.pressure, 0), 4))], s.pressure >= 2),
                chip("cpu", "Processor \(Int((s.cpuBusy * 100).rounded()))%", s.cpuBusy > 0.8),
                chip("internaldrive", "\(size(UInt64(max(s.diskFree, 0)))) free", s.diskFree < 20 << 30),
            ]))
        } else {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            root.addArrangedSubview(row(spacing: 8, [spinner, label("Checking your Mac…", .preferredFont(forTextStyle: .headline))]))
        }
        if let n = model.note {
            let banner = row(spacing: 7, [symbol(n.icon, .callout, n.color), label(n.text, .boldSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize), wraps: 356)])
            root.addArrangedSubview(boxed(banner, padding: 8, radius: 8, fill: faded(n.color, 0.12)))
        }

        let cards = column(spacing: 12)
        for f in main.prefix(3) { cards.addArrangedSubview(card(f)) }
        if main.count > 3 {
            cards.addArrangedSubview(fold("More causes", "\(main.count - 3)", open: showMore) { [weak self] in self?.showMore.toggle(); self?.animateNext = true; self?.render() })
            if showMore || forceOpen { for f in main.dropFirst(3) { cards.addArrangedSubview(card(f)) } }
        }
        if !left.isEmpty {
            cards.addArrangedSubview(fold("Left running", "\(left.count) · \(size(left.reduce(0) { $0 + $1.bytes }))", open: showLeftovers) { [weak self] in
                self?.showLeftovers.toggle()
                self?.animateNext = true
                self?.render()
            })
            if showLeftovers || forceOpen { for f in left { cards.addArrangedSubview(card(f)) } }
        }
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let page = FlippedView()
        page.addSubview(cards)
        cards.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([cards.topAnchor.constraint(equalTo: page.topAnchor), cards.leadingAnchor.constraint(equalTo: page.leadingAnchor),
                                     cards.widthAnchor.constraint(equalToConstant: 372)])
        let height = cards.fittingSize.height
        page.frame = NSRect(x: 0, y: 0, width: 372, height: height)
        scroll.documentView = page
        NSLayoutConstraint.activate([scroll.widthAnchor.constraint(equalToConstant: 372),
                                     scroll.heightAnchor.constraint(equalToConstant: min(height, (NSScreen.main?.visibleFrame.height ?? 800) - 260))])
        root.addArrangedSubview(scroll)

        let line = NSBox()
        line.boxType = .separator
        root.addArrangedSubview(line)
        line.widthAnchor.constraint(equalToConstant: 372).isActive = true
        let age = model.snap.map { openedAt.timeIntervalSince($0.now) } ?? 0
        let status = model.busy ? "Checking…" : model.snap == nil ? "" : age < 10 ? "Updated just now" : "Updated \(ago(age)) ago"
        root.addArrangedSubview(row(spacing: 10, [
            label(status, .preferredFont(forTextStyle: .caption1), .secondaryLabelColor), spacer(),
            iconButton("arrow.clockwise", tip: "Check again", enabled: !model.busy) { [weak self] in self?.model.refresh(fresh: true) },
            iconButton("ellipsis.circle", tip: nil) { [weak self] in self?.showMenu() },
        ]))
        return root
    }

    private func card(_ f: Finding) -> NSView {
        let open = forceOpen || model.openCard == f.id
        let primary = f.steps.compactMap(\.action).first ?? f.actions.first
        let icon: NSView
        if f.icon.hasPrefix("/") {
            let image = NSImageView(image: NSWorkspace.shared.icon(forFile: f.icon))
            image.imageScaling = .scaleProportionallyUpOrDown
            icon = image
        } else {
            icon = symbol(f.icon, .init(pointSize: 17, weight: .regular), .secondaryLabelColor)
        }
        let iconBox = NSView()
        iconBox.addSubview(icon)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([iconBox.widthAnchor.constraint(equalToConstant: 28), iconBox.heightAnchor.constraint(equalToConstant: 28),
                                     icon.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor), icon.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor)])
        if f.icon.hasPrefix("/") {
            NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 28), icon.heightAnchor.constraint(equalToConstant: 28)])
        }

        let width: CGFloat = 372 - 20 - 28 - 10
        let metric = f.metric.map { label($0, .monospacedDigitSystemFont(ofSize: 10, weight: .regular), .secondaryLabelColor) }
        // The title wraps at width - metric - 16: 6 pt on each side of a spacer that is at least 4 pt wide.
        let title = row(spacing: 6, align: .firstBaseline, [label(f.title, .systemFont(ofSize: 12, weight: .semibold), wraps: width - (metric?.fittingSize.width ?? -12) - 16), spacer()])
        if let metric { title.addArrangedSubview(metric) }
        title.widthAnchor.constraint(equalToConstant: width).isActive = true
        let text = column(spacing: 3, [title, label(f.summary, .preferredFont(forTextStyle: .callout), .secondaryLabelColor, wraps: width)])
        let buttons = row(spacing: 10, [])
        if let a = primary { buttons.addArrangedSubview(button(a.label, prominent: true, tip: a.fix.command, enabled: !model.busy) { [weak self] in self?.model.run(a, on: f) }) }
        buttons.addArrangedSubview(link(open ? "Less" : "Details") { [weak self] in
            guard let self else { return }
            if !open { self.model.guess(for: f) }
            self.animateNext = true
            self.model.openCard = open ? nil : f.id
        })
        text.addArrangedSubview(buttons)
        text.setCustomSpacing(6, after: text.arrangedSubviews[1])
        if open { text.addArrangedSubview(details(f, primary, width)) }
        return boxed(row(spacing: 10, align: .top, [iconBox, text]), padding: 10, radius: 10, fill: faded(.labelColor, 0.04), width: 372)
    }

    private func details(_ f: Finding, _ primary: Action?, _ width: CGFloat) -> NSView {
        let box = column(spacing: 6)
        box.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 0, right: 0)
        if let g = f.evidence.flatMap({ model.guesses[$0] }) {
            let line = row(spacing: 7, align: .firstBaseline, [symbol("sparkles", .callout, .labelColor), label(g, .preferredFont(forTextStyle: .callout), wraps: width - 24)])
            line.toolTip = "A guess by the on-device AI model, from the facts below. It can be wrong."
            box.addArrangedSubview(line)
        }
        box.addArrangedSubview(label(f.detail, .preferredFont(forTextStyle: .callout), .secondaryLabelColor, wraps: width))
        for (i, step) in f.steps.enumerated() {
            let body = column(spacing: 4, [label(step.text, .preferredFont(forTextStyle: .callout), wraps: width - 20)])
            if let a = step.action, a.id != primary?.id {
                body.addArrangedSubview(button(a.label, prominent: false, tip: a.fix.command, enabled: !model.busy) { [weak self] in self?.model.run(a, on: f) })
            }
            box.addArrangedSubview(row(spacing: 6, align: .firstBaseline, [label("\(i + 1).", .monospacedDigitSystemFont(ofSize: 12, weight: .regular), .secondaryLabelColor), body]))
        }
        for a in f.actions where a.id != primary?.id {
            box.addArrangedSubview(button(a.label, prominent: false, tip: a.fix.command, enabled: !model.busy) { [weak self] in self?.model.run(a, on: f) })
        }
        return box
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(item("Copy report") { [weak self] in self?.model.copyReport() })
        let login = item("Open at login") {
            if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() } else { try? SMAppService.mainApp.register() }
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        if ghBin != nil {
            let pr = item("Show pull request titles") { [weak self] in
                UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "prTitles"), forKey: "prTitles")
                self?.model.refresh()
            }
            pr.state = UserDefaults.standard.bool(forKey: "prTitles") ? .on : .off
            menu.addItem(pr)
        }
        menu.addItem(.separator())
        menu.addItem(item("Quit whyslow") { NSApp.terminate(nil) })
        NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent ?? NSEvent(), for: panel.contentView!)
    }

    // MARK: building blocks

    private func label(_ text: String, _ font: NSFont, _ color: NSColor = .labelColor, wraps width: CGFloat? = nil) -> NSTextField {
        let field = width == nil ? NSTextField(labelWithString: text) : NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = color
        field.isSelectable = false
        if let width { field.preferredMaxLayoutWidth = width }
        return field
    }

    // Symbols next to text are sized from the text style, so they scale with it.
    private func symbol(_ name: String, _ style: NSFont.TextStyle, _ color: NSColor) -> NSImageView {
        symbol(name, .init(textStyle: style), color)
    }

    private func symbol(_ name: String, _ config: NSImage.SymbolConfiguration, _ color: NSColor) -> NSImageView {
        let view = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
        view.symbolConfiguration = config
        view.contentTintColor = color
        return view
    }

    private func chip(_ icon: String, _ text: String, _ warn: Bool) -> NSView {
        let color: NSColor = warn ? .systemOrange : .secondaryLabelColor
        let font = NSFont.preferredFont(forTextStyle: .caption1)
        let view = boxed(row(spacing: 8, [symbol(icon, .caption1, color), label(text, font, color)]), padding: 0, radius: 0, fill: faded(color, 0.13))
        view.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        view.layer?.cornerRadius = (font.boundingRectForFont.height + 6) / 2
        return view
    }

    private func fold(_ title: String, _ info: String, open: Bool, _ action: @escaping () -> Void) -> NSView {
        let chevron = symbol("chevron.right", .init(pointSize: 10, weight: .bold), .labelColor)
        if open { chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil) }
        let line = row(spacing: 6, [chevron, label(title, .systemFont(ofSize: 12, weight: .semibold)), label(info, .preferredFont(forTextStyle: .callout), .secondaryLabelColor), spacer()])
        line.addGestureRecognizer(NSClickGestureRecognizer(target: target(action), action: #selector(Target.fire)))
        return line
    }

    private func button(_ title: String, prominent: Bool, tip: String, enabled: Bool, _ action: @escaping () -> Void) -> NSButton {
        let b = NSButton(title: title, target: target(action), action: #selector(Target.fire))
        b.controlSize = .small
        b.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        b.bezelStyle = .push
        if prominent { b.bezelColor = .controlAccentColor }
        b.toolTip = tip
        b.isEnabled = enabled
        return b
    }

    private func link(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let b = NSButton(title: title, target: target(action), action: #selector(Target.fire))
        b.isBordered = false
        b.controlSize = .small
        b.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.linkColor, .font: NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))])
        return b
    }

    private func iconButton(_ name: String, tip: String?, enabled: Bool = true, _ action: @escaping () -> Void) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: name, accessibilityDescription: tip) ?? NSImage(), target: target(action), action: #selector(Target.fire))
        b.isBordered = false
        b.toolTip = tip
        b.isEnabled = enabled
        return b
    }

    private func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: #selector(Target.fire), keyEquivalent: "")
        i.target = target(action)
        return i
    }

    private func target(_ action: @escaping () -> Void) -> Target {
        let t = Target(action)
        targets.append(t)
        return t
    }
}

// NSImageView's frame is only as tall as the glyph. The header icon gets a 19 pt frame with the glyph centered,
// which is the height SwiftUI gives a .title2 symbol (measured with --snapshot).
private func lineHigh(_ view: NSView, height: CGFloat) -> NSView {
    let box = NSView()
    box.addSubview(view)
    view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([box.heightAnchor.constraint(equalToConstant: height),
                                 box.widthAnchor.constraint(equalTo: view.widthAnchor), view.centerXAnchor.constraint(equalTo: box.centerXAnchor),
                                 view.centerYAnchor.constraint(equalTo: box.centerYAnchor)])
    return box
}

// NSStackView helpers, named after the stacks they build.
private func column(spacing: CGFloat, _ views: [NSView] = []) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .vertical
    s.alignment = .leading
    s.spacing = spacing
    return s
}

private func row(spacing: CGFloat, align: NSLayoutConstraint.Attribute = .centerY, _ views: [NSView]) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .horizontal
    s.alignment = align
    s.spacing = spacing
    return s
}

// Multiplies a color's own alpha, as SwiftUI's .opacity() does; withAlphaComponent() would replace it.
private func faded(_ color: NSColor, _ opacity: CGFloat) -> NSColor {
    color.withAlphaComponent(color.alphaComponent * opacity)
}

private func spacer() -> NSView {
    let v = NSView()
    v.setContentHuggingPriority(.init(1), for: .horizontal)
    return v
}

private func boxed(_ inner: NSView, padding: CGFloat, radius: CGFloat, fill: NSColor, width: CGFloat? = nil) -> NSStackView {
    let s = column(spacing: 0, [inner])
    s.edgeInsets = NSEdgeInsets(top: padding, left: padding, bottom: padding, right: padding)
    s.wantsLayer = true
    s.layer?.cornerRadius = radius
    s.layer?.backgroundColor = fill.cgColor
    if let width {
        s.widthAnchor.constraint(equalToConstant: width).isActive = true
        inner.widthAnchor.constraint(equalToConstant: width - 2 * padding).isActive = true
    }
    return s
}

final class Target: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class Panel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .transient]
        let glass = NSVisualEffectView()
        glass.material = .popover
        glass.state = .active
        glass.blendingMode = .behindWindow
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 14
        glass.layer?.masksToBounds = true
        contentView = glass
    }

    override var canBecomeKey: Bool { true }
}
