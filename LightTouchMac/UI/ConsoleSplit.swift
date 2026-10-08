// The main pane's bottom console, after Xcode's debug area (IDEKit's
// IDEEditorArea + IDEBottomBar).
// The device sits on top, the console below, and the bar between them is the
// divider: drag it, double-click it, or use its toggle. With the console
// hidden the bar floats, transparent, over the device's bottom edge, so the
// device keeps the whole pane; only its toggle and grab handle take clicks.

import Cocoa
import LightTouchCore

/// The main pane: `top` above, the bar, then the console.
@MainActor
final class ConsoleSplitView: NSView {
    let bar = ConsoleBar()
    let log = LogTextView()
    private(set) var layout: ConsoleSplitLayout
    private let autosaveName: String
    private let defaults: UserDefaults
    // The chosen height gives way to the device's minimum when the window is
    // short, and comes back when it grows (IDEEditorArea _resizeSubviewsForHeight…).
    private lazy var consoleHeight: NSLayoutConstraint = {
        let constraint = log.heightAnchor.constraint(equalToConstant: 0)
        constraint.priority = .defaultHigh
        return constraint
    }()
    /// How far the top runs under the bar: all of it while the console is hidden, none while it shows.
    private lazy var topUnderBar = top.bottomAnchor.constraint(equalTo: bar.topAnchor)
    private let top: NSView
    private var dragStart: (layout: ConsoleSplitLayout, height: CGFloat, y: CGFloat)?

    init(top: NSView, autosaveName: String, defaults: UserDefaults = .standard) {
        self.autosaveName = autosaveName
        self.defaults = defaults
        self.top = top
        layout = ConsoleSplitLayout.load(autosaveName, from: defaults)
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        log.borderType = .noBorder
        for view in [top, bar, log] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let topMinimum = top.heightAnchor.constraint(greaterThanOrEqualToConstant: ConsoleSplitLayout.topMinimum)
        topMinimum.priority = .init(999)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: topAnchor),
            top.leadingAnchor.constraint(equalTo: leadingAnchor),
            top.trailingAnchor.constraint(equalTo: trailingAnchor),
            topUnderBar,
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            log.topAnchor.constraint(equalTo: bar.bottomAnchor),
            log.leadingAnchor.constraint(equalTo: leadingAnchor),
            log.trailingAnchor.constraint(equalTo: trailingAnchor),
            log.bottomAnchor.constraint(equalTo: bottomAnchor),
            consoleHeight, topMinimum,
        ])
        bar.onToggle = { [weak self] in self?.toggle() }
        bar.onDragBegan = { [weak self] y in
            guard let self else { return }
            dragStart = (layout, layout.isCollapsed ? 0 : log.frame.height, y)
        }
        bar.onDrag = { [weak self] y in self?.drag(to: y) }
        bar.onDragEnded = { [weak self] in
            self?.dragStart = nil
            self?.commit()
        }
        bar.onClear = { [weak self] in self?.log.clear() }
        bar.onFilter = { [weak self] in self?.log.filter = $0 }
        bar.onSource = { [weak self] in self?.sourceChanged() }
        apply(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The logs the picker offers (the selected device's and the app's). The
    /// choice follows the file name across devices.
    var sources: [URL] = [] {
        didSet {
            let chosen = (log.url ?? sources.first).map(Self.title(for:))
            bar.source.removeAllItems()
            bar.source.addItems(withTitles: sources.map(Self.title(for:)))
            if let chosen { bar.source.selectItem(withTitle: chosen) }
            if bar.source.indexOfSelectedItem < 0, !sources.isEmpty { bar.source.selectItem(at: 0) }
            sourceChanged()
        }
    }

    /// The picker's name for a log; the files keep theirs on disk.
    static func title(for log: URL) -> String {
        ["serial.log": "Device Console", "app.log": "Light Touch", "native.log": "Emulator", "usbmuxd.log": "USB"][
            log.lastPathComponent
        ]
            ?? log.lastPathComponent
    }

    private func sourceChanged() {
        let index = bar.source.indexOfSelectedItem
        log.url = sources.indices.contains(index) ? sources[index] : nil
    }

    /// The console's share of the view: everything below the bar.
    private var available: CGFloat { bounds.height - ConsoleBar.height }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePolling()
    }

    /// Show or hide, as Xcode's toggleDebuggerVisibility: animated unless Reduce Motion is on, or nothing
    /// shows it (no visible window: the animator is driven by a display link, which never fires offscreen
    /// or with the display asleep, and the height would stay where it was).
    func toggle() {
        layout.toggle()
        apply(animated: window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        commit()
    }

    private func drag(to y: CGFloat) {
        guard let dragStart else { return }
        let proposed = dragStart.height + (y - dragStart.y)
        layout.drag(from: dragStart.layout, to: proposed, in: available)
        apply(animated: false)
    }

    private func apply(animated: Bool) {
        let collapsed = layout.isCollapsed
        let target = collapsed ? 0 : layout.height
        let underBar = collapsed ? ConsoleBar.height : 0
        bar.isExpanded = !collapsed
        if !collapsed { log.isHidden = false }
        // Out of the key-view loop once it's gone, as a collapsed split pane is.
        if animated {
            NSAnimationContext.runAnimationGroup {
                $0.duration = 0.2
                consoleHeight.animator().constant = target
                topUnderBar.animator().constant = underBar
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.hideLog(ifCollapsed: collapsed) }
            }
        } else {
            consoleHeight.constant = target
            topUnderBar.constant = underBar
            hideLog(ifCollapsed: collapsed)
        }
        updatePolling()
    }

    private func hideLog(ifCollapsed collapsed: Bool) {
        if collapsed, layout.isCollapsed { log.isHidden = true }
    }

    private func commit() {
        layout.save(autosaveName, to: defaults)
    }

    private func updatePolling() {
        if window != nil, !layout.isCollapsed { log.startPolling() } else { log.stopPolling() }
    }
}

/// Xcode's debug bar: pinned at the divider, visible when the console isn't,
/// and itself the divider's grab area (IDEBottomBar.additionalGrabRectsForSplitViewDivider).
/// Collapsed it draws nothing but a bordered toggle and a grab handle beside it, over the device, and takes
/// clicks only on those two: the rest of the strip is the device's (issue 33). The handle sits by the toggle,
/// not centered, because a centered one would cover the iPad's Home button at Fit.
@MainActor
final class ConsoleBar: NSView {
    /// DVTControlBar.defaultBarHeight: 36 pt in the macOS 26 design, 27 before it.
    static let height: CGFloat = {
        if #available(macOS 26, *) { return 36 }
        return 27
    }()
    let toggleButton = NSButton()
    let source = NSPopUpButton()
    let filter = NSSearchField()
    let clearButton = NSButton()
    let handle = ConsoleBarHandle()
    private let stack = NSStackView()
    private let spacer = NSView()
    var onToggle: (() -> Void)?
    var onClear: (() -> Void)?
    var onFilter: ((String) -> Void)?
    var onSource: (() -> Void)?
    var onDragBegan: ((CGFloat) -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?

    /// Dark, whatever the system appearance, while it borders the device's gradient: just this strip, not
    /// the console under it. Otherwise (a placeholder above) it follows the system.
    var overGradient = false {
        didSet { appearance = overGradient ? NSAppearance(named: .darkAqua) : nil }
    }

    var isExpanded = false {
        didSet {
            toggleButton.state = isExpanded ? .on : .off
            // On a transparent bar the toggle needs its own border to read over the device.
            toggleButton.isBordered = !isExpanded
            toggleButton.contentTintColor = isExpanded ? .controlAccentColor : nil
            let label = isExpanded ? "Hide Console" : "Show Console"
            toggleButton.toolTip = label + " (⇧⌘Y)"
            toggleButton.setAccessibilityLabel(label)
            // The console's own controls go with it, as Xcode's console footer does.
            for control in [source, filter, clearButton] as [NSView] { control.isHidden = !isExpanded }
            handle.isHidden = isExpanded
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 36))
        toggleButton.setButtonType(.pushOnPushOff)
        toggleButton.bezelStyle = .toolbar
        toggleButton.isBordered = false
        if #available(macOS 26, *) { toggleButton.borderShape = .roundedRectangle }
        toggleButton.image = NSImage(systemSymbolName: "inset.filled.bottomthird.square", accessibilityDescription: nil)
        toggleButton.target = self
        toggleButton.action = #selector(toggle)
        source.controlSize = .small
        source.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        source.setAccessibilityLabel("Log")
        source.target = self
        source.action = #selector(sourceChosen)
        filter.controlSize = .small
        filter.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        filter.placeholderString = "Filter"
        filter.setAccessibilityLabel("Filter Console")
        filter.sendsSearchStringImmediately = true
        filter.target = self
        filter.action = #selector(filterChanged)
        clearButton.bezelStyle = .toolbar
        clearButton.isBordered = false
        clearButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Clear Console")
        clearButton.toolTip = "Clear Console"
        clearButton.target = self
        clearButton.action = #selector(clear)
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        for view in [toggleButton, handle, source, spacer, filter, clearButton] { stack.addArrangedSubview(view) }
        stack.spacing = 8
        stack.detachesHiddenViews = true
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            filter.widthAnchor.constraint(equalToConstant: 180),
            handle.widthAnchor.constraint(equalToConstant: 32), handle.heightAnchor.constraint(equalToConstant: 24),
        ])
        isExpanded = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var mouseDownCanMoveWindow: Bool { false }

    /// The divider line on top and a second line under the bar while the console
    /// shows (IDEEditorArea sets the bar's borderSides by visibility); nothing while it's hidden.
    override func draw(_ dirtyRect: NSRect) {
        guard isExpanded else { return }
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    /// Collapsed, only the toggle and the handle are the bar's; elsewhere the click falls through to the device.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard !isExpanded, let hit else { return hit }
        return hit.isDescendant(of: toggleButton) || hit === handle ? hit : nil
    }

    /// The resize cursor over the bar's empty stretches, not over its controls; collapsed, over the handle.
    override func resetCursorRects() {
        guard isExpanded else {
            addCursorRect(handle.convert(handle.bounds, to: self), cursor: .resizeUpDown)
            return
        }
        var x = bounds.minX
        for control in stack.arrangedSubviews where !control.isHidden && control !== spacer {
            let frame = control.convert(control.bounds, to: self)
            if frame.minX > x {
                addCursorRect(NSRect(x: x, y: 0, width: frame.minX - x, height: bounds.height), cursor: .resizeUpDown)
            }
            x = max(x, frame.maxX)
        }
        if bounds.maxX > x {
            addCursorRect(NSRect(x: x, y: 0, width: bounds.maxX - x, height: bounds.height), cursor: .resizeUpDown)
        }
    }

    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        // IDEEditorArea splitView:doubleClickedOnDividerAtIndex: shows or hides the debug area.
        if event.clickCount == 2 {
            onToggle?()
            return
        }
        onDragBegan?(event.locationInWindow.y)
    }

    override func mouseDragged(with event: NSEvent) { onDrag?(event.locationInWindow.y) }
    override func mouseUp(with event: NSEvent) { onDragEnded?() }

    @objc private func toggle() { onToggle?() }
    @objc private func clear() { onClear?() }
    @objc private func sourceChosen() { onSource?() }
    @objc private func filterChanged() { onFilter?(filter.stringValue) }
}

/// The collapsed bar's grab handle: a short capsule. Its clicks and drags go up the responder chain to the bar.
@MainActor
final class ConsoleBarHandle: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.handle)
        setAccessibilityLabel("Console Divider")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.setFill()
        let capsule = NSRect(x: bounds.midX - 12, y: bounds.midY - 2.5, width: 24, height: 5)
        NSBezierPath(roundedRect: capsule, xRadius: 2.5, yRadius: 2.5).fill()
    }
}

/// The split as a pane of the window's NSSplitViewController.
@MainActor
final class ConsoleSplitViewController: NSViewController {
    private let top: NSViewController
    private let autosaveName: String
    var split: ConsoleSplitView {
        guard let split = view as? ConsoleSplitView else { preconditionFailure("loadView installs a ConsoleSplitView") }
        return split
    }

    init(top: NSViewController, autosaveName: String) {
        self.top = top
        self.autosaveName = autosaveName
        super.init(nibName: nil, bundle: nil)
        addChild(top)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() { view = ConsoleSplitView(top: top.view, autosaveName: autosaveName) }
}
