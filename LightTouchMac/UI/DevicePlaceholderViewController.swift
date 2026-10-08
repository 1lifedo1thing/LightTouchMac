// The detail area for a device that isn't running in this window: its art,
// dimmed, what it is, where it stands, and the one thing to do next.

import Cocoa
import HostRuntime
import LightTouchCore

final class DevicePlaceholderViewController: NSViewController {
    var onAction: ((DeviceAction) -> Void)?
    var onShowLog: (() -> Void)?
    var onDropIPSW: ((URL) -> Void)?

    private let art = NSImageView()
    private let model = NSTextField(labelWithString: "")
    private let version = NSTextField(labelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    /// Holds the shown entry's own bar: each job keeps its bar, so switching between two jobs never animates one bar
    /// from the other's value.
    private let progressSlot = NSView()
    private var bars: [String: NSProgressIndicator] = [:]
    private var progress: NSProgressIndicator? { progressSlot.subviews.first as? NSProgressIndicator }
    /// Under the bar: percent, time left, speed (DeviceRow.progressLine).
    private let progressLine = NSTextField(labelWithString: "")
    private let reason = NSTextField(wrappingLabelWithString: "")
    /// Beside the state line while a file system operation runs (DeviceFilesystemEdits.activity).
    private let activitySpinner = NSProgressIndicator()
    private let showLog = NSButton(title: "Show Logs", target: nil, action: nil)
    private let primary = NSButton(title: "", target: nil, action: nil)
    private let prepareAgain = NSButton(title: "Prepare Again…", target: nil, action: nil)
    /// An edit open in Finder (DeviceFilesystemEdits.hasOpenEdit): Show in Finder and Don't Save beside Save Changes.
    private let showFiles = NSButton(title: "Show in Finder", target: nil, action: nil)
    private let dontSave = NSButton(title: "Don’t Save", target: nil, action: nil)
    private let space = NSTextField(wrappingLabelWithString: "")
    /// The build's catalog note (untested, experimental, where a beta came from), in a popover.
    private let info = NSButton(
        image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: "About This Build")!,
        target: nil,
        action: nil
    )
    private var row: DeviceRow?

    override func loadView() {
        let drop = IPSWDropView()
        drop.onDrop = { [weak self] url in self?.onDropIPSW?(url) }
        view = drop

        art.imageScaling = .scaleProportionallyDown
        art.alphaValue = 0.35
        art.setAccessibilityElement(false)
        art.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        art.setContentHuggingPriority(.defaultLow, for: .vertical)
        // One column, three tiers: what it is (name, then version), where it stands (state, then its detail),
        // what to do (one button row, the default button last). The same slots in every state.
        model.font = .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .title1).pointSize, weight: .semibold)
        version.font = .preferredFont(forTextStyle: .title3)
        version.textColor = .secondaryLabelColor
        version.isSelectable = true
        for label in [status, reason, space] {
            label.alignment = .center
            label.preferredMaxLayoutWidth = 340
        }
        status.font = .preferredFont(forTextStyle: .headline)
        reason.textColor = .secondaryLabelColor
        space.textColor = .secondaryLabelColor
        space.font = .preferredFont(forTextStyle: .footnote)
        info.isBordered = false
        info.contentTintColor = .secondaryLabelColor
        info.target = self
        info.action = #selector(infoClicked(_:))
        progressLine.textColor = .secondaryLabelColor
        progressLine.font = .monospacedDigitSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize,
            weight: .regular
        )
        progressLine.alignment = .center
        for button in [showLog, prepareAgain, showFiles, dontSave, primary] {
            button.bezelStyle = .push
            button.controlSize = .large
            button.target = self
        }
        showLog.action = #selector(showLogClicked(_:))
        primary.action = #selector(primaryClicked(_:))
        prepareAgain.action = #selector(prepareAgainClicked(_:))
        showFiles.action = #selector(showFilesClicked(_:))
        dontSave.action = #selector(dontSaveClicked(_:))

        let versionLine = NSStackView(views: [version, info])
        versionLine.spacing = 4
        let identity = column([model, versionLine], spacing: 2)
        activitySpinner.style = .spinning
        activitySpinner.controlSize = .small
        activitySpinner.isDisplayedWhenStopped = false
        let statusLine = NSStackView(views: [activitySpinner, status])
        statusLine.spacing = 6
        statusLine.detachesHiddenViews = true
        let state = column([statusLine, progressSlot, progressLine, reason], spacing: 6)
        let actions = NSStackView(views: [showLog, prepareAgain, showFiles, dontSave, primary])
        actions.spacing = 12
        // The row keeps its height with no button (running), so the lockup doesn't move between states.
        actions.heightAnchor.constraint(greaterThanOrEqualTo: primary.heightAnchor).isActive = true
        actions.detachesHiddenViews = true
        let stack = column([art, identity, state, actions, space], spacing: 20)
        stack.setCustomSpacing(28, after: art)
        stack.setCustomSpacing(12, after: actions)
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: guide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 20),
            art.heightAnchor.constraint(lessThanOrEqualToConstant: 320),
            art.heightAnchor.constraint(lessThanOrEqualTo: guide.heightAnchor, multiplier: 0.45),
            progressSlot.widthAnchor.constraint(equalToConstant: 260),
            progressSlot.heightAnchor.constraint(equalToConstant: Self.makeBar().fittingSize.height),
            // The state tier holds a line and a bar, or a line and a reason: the buttons stay put (a two-line reason adds one line).
            state.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
        ])
    }

    private func column(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = spacing
        return stack
    }

    /// `activity`: a file system operation in flight on the device ("Preparing to mount the file system…"): it stands
    /// in for the state line, with a spinner, and holds the buttons. `editing`: its file system edit is open (true:
    /// mounted in Finder), which the screen says over everything else, with Save Changes, Don't Save and Show in Finder.
    func update(_ row: DeviceRow, canDownload: Bool, activity: String? = nil, editing: Bool? = nil) {
        loadViewIfNeeded()
        self.row = row
        let entry = row.entry
        let profile = entry.profile
        // The sidebar's thumbnail (Finder's artwork for the model), at the size of the lockup.
        art.image = profile.map { profile in
            let image = profile.icon.copy() as! NSImage
            image.size = NSSize(width: 256, height: 256)
            return image
        }
        model.stringValue = profile?.marketingName ?? entry.productType
        version.stringValue = "iOS \(entry.version)" + (row.badge.map { " \($0)" } ?? "") + " (\(entry.build))"
        info.isHidden = row.catalogNote == nil

        progressSlot.isHidden = true
        progressLine.isHidden = true
        progress?.stopAnimation(nil)
        reason.isHidden = true
        showLog.isHidden = true
        prepareAgain.isHidden = true
        showFiles.isHidden = editing == nil
        dontSave.isHidden = editing == nil
        status.isHidden = false
        switch row.state {
        case .bundled, .notDownloaded, .downloaded:
            status.stringValue = row.stateDescription
            if !canDownload, let why = FirmwareJobs.shared.unavailableReason {
                reason.stringValue = why
                reason.isHidden = false
            }
        case .downloading:
            show(row).setAccessibilityLabel("Download progress")
        case .preparing:
            show(row).setAccessibilityLabel("Preparation progress")
        case .ready:
            status.stringValue = "Ready"
            // Start stays the default: an older base still runs.
            if let note = row.olderRecipeNote {
                reason.stringValue = note
                reason.isHidden = false
                prepareAgain.isHidden = false
                prepareAgain.isEnabled = row.allows(.prepareAgain, canDownload: canDownload)
            }
        case .running: status.stringValue = "Running"
        case .stopping: status.stringValue = "Stopping…"
        case .deleting: status.stringValue = "Deleting…"
        case .error(let message):
            // What failed, over why (the reason).
            status.stringValue =
                row.hasSession ? "Stopped unexpectedly" : row.isStartable ? "Couldn’t start" : "Couldn’t prepare"
            reason.stringValue = message
            reason.isHidden = false
            showLog.isHidden = false
        case .unavailable(.comingSoon): status.stringValue = "Coming soon"
        case .unavailable(.requiresIPSW): status.stringValue = "Requires an IPSW"
        }

        if row.progressHeadline == nil { bars[entry.id] = nil }

        if let editing {
            status.stringValue = "Editing file system"
            reason.stringValue =
                editing
                ? "It’s open in Finder. Ejecting it there also saves your changes."
                : "Show it in Finder to keep editing."
            reason.isHidden = false
            prepareAgain.isHidden = true
        }

        if let activity {
            status.stringValue = activity
            activitySpinner.isHidden = false
            activitySpinner.startAnimation(nil)
        } else {
            activitySpinner.stopAnimation(nil)
            activitySpinner.isHidden = true
        }

        showFiles.isEnabled = activity == nil
        dontSave.isEnabled = activity == nil
        if editing != nil {
            primary.title = "Save Changes"
            primary.keyEquivalent = "\r"
            primary.isEnabled = activity == nil
            primary.isHidden = false
            primary.setAccessibilityLabel("Save Changes to \(model.stringValue)’s file system")
        } else if let action = row.primaryAction, let title = row.primaryTitle {
            primary.title = title
            // Return does the next thing; it never cancels a download (Escape does).
            primary.keyEquivalent = action == .cancel ? "\u{1b}" : "\r"
            primary.isEnabled = row.allows(action, canDownload: canDownload) && activity == nil
            primary.isHidden = false
            primary.setAccessibilityLabel("\(title) \(model.stringValue) iOS \(entry.version)")
        } else {
            primary.isHidden = true
        }

        // Disk numbers only when they stop a download or preparation.
        // (spaceShortage(available: 0) is nil for a row that needs no space: skip the volume query on every progress tick.)
        let shortage =
            row.spaceShortage(available: 0) == nil
            ? nil
            : (try? IPSWStore.availableSpace(at: Bundled.stateDirectory)).flatMap(row.spaceShortage(available:))
        space.stringValue = shortage ?? ""
        space.isHidden = shortage == nil
    }

    private static func makeBar() -> NSProgressIndicator {
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = false  // NSProgressIndicator starts indeterminate: a bar that never fills
        bar.minValue = 0
        bar.maxValue = 1
        return bar
    }

    /// The stage over the entry's own bar (moving without a fraction yet), the percent, time left and speed under it;
    /// the preparer's step is the bar's tooltip. Returns the bar.
    @discardableResult private func show(_ row: DeviceRow) -> NSProgressIndicator {
        status.stringValue = row.progressHeadline ?? ""
        let bar = bars[row.entry.id] ?? Self.makeBar()
        bars[row.entry.id] = bar
        if progress !== bar {
            progressSlot.subviews.forEach { $0.removeFromSuperview() }
            bar.frame = progressSlot.bounds
            bar.autoresizingMask = [.width, .height]
            progressSlot.addSubview(bar)
        }
        bar.isIndeterminate = row.progress == nil
        if let value = row.progress { bar.doubleValue = value } else { bar.startAnimation(nil) }
        progressSlot.isHidden = false
        bar.toolTip = row.progressDetail.isEmpty ? nil : row.progressDetail.joined(separator: "\n")
        progressLine.stringValue = row.progressLine ?? ""
        progressLine.isHidden = row.progressLine == nil
        return bar
    }

    @objc private func infoClicked(_ sender: NSButton) {
        guard let row, let content = Self.infoContent(for: row) else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = content
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    /// The ⓘ popover: the support tag and what it means, the catalog's source note, the release date.
    /// Sized to fit before it is shown: a view controller's bare NSView() is 0×0, and a popover that
    /// takes that size shows nothing (RC1).
    static func infoContent(for row: DeviceRow) -> NSViewController? {
        guard row.catalogNote != nil else { return nil }
        func label(_ text: String?, _ style: NSFont.TextStyle, _ color: NSColor = .labelColor) -> NSTextField? {
            guard let text else { return nil }
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .preferredFont(forTextStyle: style)
            label.textColor = color
            label.isSelectable = true
            label.preferredMaxLayoutWidth = 280
            return label
        }
        let stack = NSStackView(
            views: [
                label(row.supportNote, .headline), label(row.supportExplanation, .body, .secondaryLabelColor),
                label(row.entry.statusNote, .body), label(row.releaseLine, .subheadline, .secondaryLabelColor),
            ]
            .compactMap { $0 }
        )
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.widthAnchor.constraint(equalToConstant: 308).isActive = true
        let content = NSViewController()
        content.view = stack
        stack.frame.size = stack.fittingSize
        content.preferredContentSize = stack.frame.size
        return content
    }

    @objc private func primaryClicked(_ sender: Any?) {
        guard let action = showFiles.isHidden ? row?.primaryAction : .commitFilesystem else { return }
        onAction?(action)
    }
    @objc private func showFilesClicked(_ sender: Any?) { onAction?(.openFilesystem) }
    @objc private func dontSaveClicked(_ sender: Any?) { onAction?(.discardFilesystem) }

    @objc private func prepareAgainClicked(_ sender: Any?) { onAction?(.prepareAgain) }

    @objc private func showLogClicked(_ sender: Any?) { onShowLog?() }
}

/// Takes .ipsw files dropped anywhere on the placeholder.
private final class IPSWDropView: NSView {
    var onDrop: ((URL) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func ipsws(_ sender: NSDraggingInfo) -> [URL] {
        DroppedFiles.files(
            sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL] ?? [],
            .ipsw
        )
    }

    private lazy var highlight = DropHighlight.install(in: self)
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlight.show(for: ipsws(sender).isEmpty ? [] : .copy)
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlight.show(for: []) }
    override func draggingEnded(_ sender: NSDraggingInfo) { highlight.show(for: []) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = ipsws(sender)
        urls.forEach { onDrop?($0) }
        return !urls.isEmpty
    }
}
