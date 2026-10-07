import LightTouchCore
import HostServiceWire
import HostServiceClient
import HostRuntime
import DeviceRuntime
// Created by Sam on 2026-08-05.
//
// The right-hand inspector: a plain AppKit table of the apps installed on the
// device, in the order they sit on the home screen, with add (install an .ipa)
// and remove (uninstall) controls beneath it, source-list style. Rows can be
// dragged to reorder the home screen itself, and right-clicked for the same
// operations. While an install runs, the app appears as a pending row carrying
// the script's own progress, cancellable from its context menu.

import Cocoa
import UniformTypeIdentifiers

final class AppsInspectorViewController: NSViewController {

    private let emulator: EmulatorController
    private let tableView = NSTableView()
    private let addRemove = NSSegmentedControl()
    private let searchField = NSSearchField()
    private let placeholder = NSTextField.paneMessage()
    private let emptyActions = NSStackView()
    private let browseButton = NSButton(title: "Browse Store", target: nil, action: nil)
    private let installButton = NSButton(title: "Install App…", target: nil, action: nil)
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let resumeButton = NSButton(title: "Resume", target: nil, action: nil)
    private var queries: [PaneMode: String] = [:]
    private var catalogFailed = false

    /// Shown over a populated list when the device stops answering: the list is
    /// kept (it was correct a moment ago) but no longer silently pretends to be
    /// current.
    private let banner = NSTextField.paneCaption()
    private var bannerHeight: NSLayoutConstraint?
    private var lastLoaded: Date?
    private var apps: [InstalledApp] = []
    private var pending: [InstallJob] = []
    /// Bundle IDs in home-screen order, empty until SpringBoard tells us. The
    /// list is sorted by this when we have it, so the sidebar and the icons
    /// read the same way down the screen.
    private var homeOrder: [String] = []
    /// Set once the device has answered at all — until then an empty list means
    /// "we don't know yet", not "nothing is installed".
    private var haveLoaded = false
    private var loadTask: Task<Void, Never>?
    // MARK: Catalog (Store) state
    //
    // The table has exactly two modes, switched by the Installed/Store
    // segmented control (typing a search flips to Store; Store with an empty
    // search shows the suggested list): the installed list (pending +
    // visibleApps, whose index arithmetic is deliberately untouched) or the
    // Legacy Store results. Never both — a third section interleaved into the
    // installed list would have to reconcile with prunePending/visibleApps at
    // every step.
    enum PaneMode: Int { case installed = 0, store = 1 }
    /// Store first: the default view is the suggested list, ready to install.
    private var mode: PaneMode = .store
    private let modeControl = NSSegmentedControl(labels: ["Installed", "Store"],
                                                 trackingMode: .selectOne,
                                                 target: nil, action: nil)
    /// What the server returned; the table shows catalogResults, these through the filter menu.
    private var catalogFetched: [CatalogApp] = []
    private var catalogResults: [CatalogApp] { filterButton.apply(catalogFetched) }
    private lazy var filterButton = CatalogFilterButton(isIPad: emulator.profile.facts.kind == .iPad)
    private var searchTask: Task<Void, Never>?
    /// The table is showing Legacy Store content.
    private var searching: Bool { mode == .store }
    /// One list read at a time; see loadOnce.
    private var isLoading = false
    /// A refresh arrived while one was running; run once more when it finishes.
    private var needsReload = false
    private var notifications: NotificationProxy?
    private var notificationEndpoint: HostServiceEndpoint?

    init(emulator: EmulatorController) {
        self.emulator = emulator
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let container = NSView()

        let column = NSTableColumn(identifier: .init("app"))
        column.title = "Installed Apps"
        tableView.addTableColumn(column)
        tableView.headerView = nil
        // A source list, which is what an inspector's list of things is: it
        // brings the standard row inset, selection material and — the reason
        // the old reordering looked homemade — AppKit's own drag feedback.
        tableView.style = .sourceList
        tableView.rowHeight = 56
        tableView.dataSource = self
        tableView.delegate = self
        // .string is the internal reorder drag; .fileURL is an .ipa dropped
        // from the Finder. The list of installed apps is the obvious place to
        // drop an app, and it silently ignored one — two inches to the left, on
        // the device screen, the same drop installed it.
        tableView.registerForDraggedTypes([.string, .fileURL])
        // Rows leave the app: installed rows as .ipa files (to the Finder),
        // Store rows as links — and both drop on the device view (local .copy).
        tableView.setDraggingSourceOperationMask([.copy], forLocal: false)
        tableView.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        let menu = NSMenu()
        menu.delegate = self
        // menuNeedsUpdate decides what is enabled; automatic enabling would
        // overrule it and re-enable Cancel Install on a job already cancelling.
        menu.autoenablesItems = false
        tableView.menu = menu
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        configureAddRemove()

        placeholder.isHidden = true

        // A quiet caption, the way Mail dates its last check — no fill at all.
        // Both a yellow band and a gray quaternary strip were tried; any
        // edge-to-edge fill under the segmented control reads as a broken
        // control, not a status line.
        banner.isHidden = true
        let bannerHeight = banner.heightAnchor.constraint(equalToConstant: 0)
        self.bannerHeight = bannerHeight

        modeControl.selectedSegment = mode.rawValue
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        modeControl.segmentDistribution = .fillEqually
        modeControl.controlSize = .large
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        // Both modes act on several rows at once: bulk install in the Store,
        // bulk uninstall in Installed.
        tableView.allowsMultipleSelection = true

        for (button, action) in [(browseButton, #selector(browseStore)), (installButton, #selector(installLocal)),
                                 (retryButton, #selector(refreshClicked(_:))), (resumeButton, #selector(resumeInstallsClicked(_:)))] {
            button.target = self; button.action = action; button.bezelStyle = .rounded
        }
        for button in [browseButton, installButton, retryButton] { emptyActions.addArrangedSubview(button) }
        emptyActions.spacing = 8
        emptyActions.translatesAutoresizingMaskIntoConstraints = false
        emptyActions.isHidden = true
        resumeButton.translatesAutoresizingMaskIntoConstraints = false
        resumeButton.isHidden = true
        filterButton.translatesAutoresizingMaskIntoConstraints = false
        filterButton.isEnabled = mode == .store
        filterButton.onChange = { [weak self] in self?.filterChanged() }
        [modeControl, filterButton, banner, scroll, placeholder, emptyActions, resumeButton].forEach(container.addSubview)
        // Everything hangs below the safe area — a hard edge at the toolbar,
        // so rows can never slide behind the search field (full-bleed +
        // automatic insets let them scroll under the glass, unblurred and
        // unreadable; the only system knob for that edge,
        // preferredScrollEdgeEffectStyle, exists on accessory controllers,
        // not plain toolbars). Pre-26 the safe area is simply the pane.
        var constraints = [
            modeControl.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 6),
            modeControl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            filterButton.leadingAnchor.constraint(equalTo: modeControl.trailingAnchor, constant: 4),
            filterButton.centerYAnchor.constraint(equalTo: modeControl.centerYAnchor),
            filterButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),

            banner.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 6),
            banner.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            banner.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            bannerHeight,

            scroll.topAnchor.constraint(equalTo: banner.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            emptyActions.topAnchor.constraint(equalTo: placeholder.bottomAnchor, constant: 12),
            emptyActions.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            resumeButton.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            resumeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            placeholder.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            placeholder.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            placeholder.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
        ]
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(footer)
        footer.addSubview(addRemove)
        footerHeight = footer.heightAnchor.constraint(equalToConstant: 0)
        constraints += [
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor), footerHeight!,
            addRemove.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 10),
            addRemove.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ]
        NSLayoutConstraint.activate(constraints)

        view = container
        updateFooterVisibility()
    }

    /// The catalog search lives in the window toolbar (the standard Mac home
    /// for search — App Store, Mail), riding above the inspector thanks to the
    /// tracking separator. A custom top-accessory strip was tried first and
    /// fought the scroll-edge system: rows rendered over the toolbar.
    private weak var searchToolbarItem: NSSearchToolbarItem?

    func attachSearchField(to item: NSSearchToolbarItem) {
        configureSearchField()
        item.searchField = searchField
        searchToolbarItem = item
    }

    private func configureSearchField() {
        searchField.placeholderString = mode == .store ? "Search Store" : "Search Installed Apps"
        searchField.delegate = self
        // The cancel button clears the text and sends the action without a
        // controlTextDidChange; route both through the same handler.
        searchField.target = self
        searchField.action = #selector(searchEdited)
    }

    private var footerHeight: NSLayoutConstraint?
    private func updateFooterVisibility() {
        addRemove.isHidden = mode == .store
        footerHeight?.constant = mode == .store ? 0 : 34
    }

    private func configureAddRemove() {
        addRemove.segmentStyle = .smallSquare
        addRemove.trackingMode = .momentary
        addRemove.segmentCount = 2
        addRemove.setImage(NSImage(systemSymbolName: "plus", accessibilityDescription: "Install App"), forSegment: 0)
        addRemove.setImage(NSImage(systemSymbolName: "minus", accessibilityDescription: "Uninstall App"), forSegment: 1)
        addRemove.target = self
        addRemove.action = #selector(addOrRemove(_:))
        addRemove.translatesAutoresizingMaskIntoConstraints = false
        // Start disabled and let updateButtons() turn them on. Enabled-by-
        // default meant they were live all through the boot wait.
        addRemove.setEnabled(false, forSegment: 0)
        addRemove.setEnabled(false, forSegment: 1)
        updateButtons()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appsChanged(_:)), name: .ltmAppsChanged, object: nil)
        nc.addObserver(self, selector: #selector(installStarted(_:)), name: .ltmInstallStarted, object: nil)
        nc.addObserver(self, selector: #selector(installProgressed(_:)), name: .ltmInstallProgress, object: nil)
        nc.addObserver(self, selector: #selector(refreshIconDimming), name: NSApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(refreshIconDimming), name: NSApplication.didResignActiveNotification, object: nil)
        statusTracking = ObservationLoop(read: { [weak self] in self?.trackedDeviceState() },
                                         onChange: { [weak self] in self?.deviceStatusChanged() })
        startInitialLoad()
        scheduleSearch()   // Store is the default view — fetch the suggested list
    }

    // MARK: - Loading / refresh

    /// Keep polling for the life of the view, not just until the device answers
    /// once: right after boot, installation_proxy can answer with an empty
    /// list before installd has finished registering apps, which used to read
    /// as "answered" and stop the loop — leaving the sidebar empty until an
    /// install/uninstall notification forced a reload. Polling forever instead
    /// self-heals within one more tick either way.
    private func startInitialLoad() {
        guard emulator.canManageApps else {
            showInstalledPlaceholder("Apps can’t be managed without a USB connection.")
            updateButtons()
            return
        }
        // Push, so an install or uninstall shows up at once instead of on the
        // next tick. The poll below stays as the backstop.
        startGuestNotifications()
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                // Ask "is the device even up?" in-process before spawning
                // anything: the probe answers in milliseconds, so a cold boot
                // no longer costs one failing lockdown session per
                // second, and a transient lockdown wobble skips a poll
                // instead of failing it. Not while installing — the probe is
                // itself a lockdown session, the very thing being avoided.
                if self.readsSuppressed {
                    // Reads are suppressed while our own device work runs, but
                    // "unknown" is not "reachable": leaving the last value
                    // frozen meant Install App…, the toolbar and drag-to-install
                    // all kept claiming a device that might have gone away ten
                    // minutes ago. The type already models this as nil.
                    self.emulator.deviceReachable = nil
                } else {
                    do {
                        try await self.emulator.checkDeviceConnection()
                        // A transfer may have started while the probe waited
                        // for its service slot. Its wait is not a device fault.
                        guard !Task.isCancelled else { return }
                        if !self.readsSuppressed { await self.loadOnce() }
                    } catch is CancellationError {
                        return
                    } catch {
                        if !self.readsSuppressed {
                            self.emulator.reportConnectionFailure(error, operation: "Checking USB connection")
                            if !self.haveLoaded, self.pending.isEmpty {
                                self.showInstalledPlaceholder(self.emulator.connectionIssue?.summary ?? "Connecting to \(self.emulator.profile.shortName)…")
                            } else if self.haveLoaded {
                                self.showStaleBanner()
                            }
                            self.updateButtons()
                        }
                    }
                }
                // Press hard until the device has answered once — a cold boot
                // takes ~40 s and the list is the first thing anyone looks at.
                // After that this is only a BACKSTOP: notification_proxy pushes
                // install/uninstall the moment they happen, so the poll exists
                // for what the guest never publishes (icon reordering) and for
                // a dropped session, neither of which needs a 3 s cadence. An
                // unactivated guest refuses every service: nothing to press for.
                try? await Task.sleep(for: .seconds(self.haveLoaded || self.emulator.connectionIssue?.persistent == true ? 15 : 1))
            }
        }
    }

    @objc private func refreshIconDimming() {
        // Catalog mode: different row count, and pending.count may exceed it —
        // the range below would raise. Catalog rows redraw on reload anyway.
        guard !searching else { return }
        for row in pending.count..<numberOfRows(in: tableView) {
            (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView)?
                .imageView?.layer?.opacity = NSApp.isActive ? 1 : 0.5
        }
    }

    /// Drop finished install rows, but not before the device admits the app
    /// exists. instproxy does not list a newly installed app the instant the
    /// install call returns, so removing the row on completion left a window
    /// with neither the pending row nor a real one — the app appeared to vanish
    /// and only came back on a manual refresh. Bounded, so a failed install (or
    /// one whose bundle id we never learned) cannot strand a row forever.
    private func prunePending() {
        pending.removeAll { job in
            if job.dismissed { return true }
            guard job.isFinished else { return false }
            if job.failed { return false }
            if job.isCancelled { return true }   // nothing will ever appear
            guard let id = job.bundleID else {
                return Date().timeIntervalSince(job.finishedAt ?? Date()) > 15
            }
            if apps.contains(where: { $0.id == id }) { return true }
            // Two bounds, not one. At 20s ask the device again rather than
            // dropping the row blind — deleting it reopened the "app vanished
            // from the sidebar" gap this row exists to close, just 20 seconds
            // later. At 60s give up anyway, because a row that can never leave
            // is its own bug.
            let age = Date().timeIntervalSince(job.finishedAt ?? Date())
            if age > 60 { return true }
            if age > 20 { Task { await self.loadOnce() } }
            return false
        }
    }

    /// The rows on screen; see AppTableRows.
    private var displayed = AppTableRows()

    /// What the inspector knows, as the table's rows (LightTouchCore's AppsInspectorRows).
    private var rows: AppsInspectorRows {
        AppsInspectorRows(searching: searching, apps: apps, pending: pending, installedQuery: queries[.installed, default: ""],
                          catalogResults: catalogResults, uninstalling: uninstalling, removingApp: removingApp, device: device,
                          displayName: { [unowned self] in displayName($0) },
                          icons: AppRowIcons(catalog: { [unowned self] in catalogIcon($0).map(ObjectIdentifier.init) },
                                             pending: { [unowned self] in pendingIcon($0).map(ObjectIdentifier.init) },
                                             installed: { AppMetadataCache.shared.icon(for: $0).map(ObjectIdentifier.init) }))
    }

    /// The device, as the rows and menus weigh it.
    private var device: AppsDevice {
        AppsDevice(id: emulator.instance.id, canQueueInstall: emulator.canQueueInstall, canReachDevice: emulator.canReachDevice,
                   installing: installing, preparingDevice: emulator.preparingDevice, hasFileTransfer: emulator.hasFileTransfer,
                   isReconnecting: emulator.isReconnecting, transfersPaused: AppInstaller.isPaused(emulator.instance.id))
    }

    /// Keep selection attached to objects, rebuilding only changed rows. An
    /// unchanged background poll leaves native views and accessibility intact.
    private func reloadTablePreservingSelection() {
        let rows = rows
        switch displayed.show(rows.identities, rows.appearances, selected: tableView.selectedRowIndexes) {
        case .rows(let changed): tableView.reloadData(forRowIndexes: changed, columnIndexes: [0])
        case .table(let selection):
            tableView.reloadData()
            tableView.selectRowIndexes(selection, byExtendingSelection: false)
        case nil: break
        }
    }

    @objc private func appsChanged(_ note: Notification) {
        if let device = note.object as? UUID, device != emulator.instance.id { return }
        prunePending()
        // Reload NOW, not from loadOnce: its failure path doesn't touch the
        // table, and an install that failed because the device died is exactly
        // the case where the next read fails too — leaving a phantom pending
        // row on screen while every data-source index has shifted up one (the
        // right-click-hits-the-wrong-app bug).
        reloadTablePreservingSelection()
        updateButtons()
        Task { await loadOnce() }
    }

    /// The rows' buttons follow the device (Install needs `canQueueInstall`): booting, readiness, USB and
    /// power changes re-evaluate them here, not on the next poll that happens to reload the table. Unchanged
    /// rows keep their views (reloadTablePreservingSelection compares appearances).
    private var statusTracking: ObservationLoop?
    /// What of the device the rows and buttons show: its reachability and install state (`device`), not the
    /// status line's every tick.
    private func trackedDeviceState() { _ = device }
    private func deviceStatusChanged() {
        reloadTablePreservingSelection()
        updateButtons()
    }

    @objc private func installStarted(_ note: Notification) {
        guard let job = note.object as? InstallJob, job.deviceID == emulator.instance.id else { return }
        pending.append(job)
        if AppsInspector.revealsTransfer(job) {
            setMode(.installed)
            if let split = parent as? NSSplitViewController,
               let item = split.splitViewItem(for: self) { item.animator().isCollapsed = false }
        }
        showInstalledPlaceholder(nil)
        reloadTablePreservingSelection()
        if AppsInspector.revealsTransfer(job) { tableView.scrollRowToVisible(pending.count - 1) }
        updateButtons()
    }

    @objc private func installProgressed(_ note: Notification) {
        guard let job = note.object as? InstallJob, job.deviceID == emulator.instance.id else { return }
        reloadTablePreservingSelection()
        updateButtons()
    }

    private var poweringDown: Bool { emulator.shuttingDown || emulator.isPoweredOff || emulator.isErasing }

    /// One attempt to read the installed list.
    ///
    /// A failed read leaves the previous list on screen. It used to replace it
    /// with an empty one — every transient "could not start the service" blanked
    /// a sidebar that was perfectly correct a second earlier, and read as the
    /// list having lost its contents for no reason.
    private func loadOnce() async {
        // Not while powering off. Power Off and Erase post .ltmAppsChanged
        // (discardAll) as they start, and the guest halt goes over the agent,
        // not the gate, so this read raced installd going down: "Install
        // service error (browse): code -8" (APIInternalError) at Power Off.
        guard emulator.canManageApps, !poweringDown else { return }
        // Nothing talks to the device while an install runs (see `installing`);
        // the finish notification reloads the list anyway.
        guard !readsSuppressed else { return }
        // One at a time. Every .ltmAppsChanged used to spawn another of these,
        // and an upgrade publishes two notifications back to back — so two
        // reads queued on the gate for up to 20s each and the SLOWER, older one
        // assigned `apps` last, putting a stale list on screen.
        // Coalesce, don't drop. A refresh that arrives while one is in flight
        // used to be discarded outright — and the read already running was
        // started BEFORE the change that prompted it, so the list it publishes
        // is already stale. Notification-driven refreshes, the post-reorder
        // re-read and the user's own Refresh all went through this path, which
        // is a large part of "the list and the home screen fall out of sync".
        guard !isLoading else { needsReload = true; return }
        isLoading = true
        defer {
            isLoading = false
            if needsReload { needsReload = false; Task { await loadOnce() } }
        }
        do {
            let live = try await emulator.services.installedApps()
            // Read the home-screen order BEFORE publishing anything. Assigning
            // `apps` and then awaiting left the data source reporting a row
            // count the table had never been told about, and anything that
            // re-queried it during that window (a layout pass, the
            // active/inactive icon dimming) asked for a row that did not exist
            // — an out-of-range raise, not a glitch.
            let order = (try? await emulator.services.homeScreenOrder()) ?? homeOrder
            // No suspension points from here to reloadData().
            apps = live
            homeOrder = order
            haveLoaded = true
            lastLoaded = Date()
            emulator.deviceReachable = true
            hideStaleBanner()
            // SpringBoard publishes no notification when icons are rearranged
            // on the device — notification_proxy carries application_installed
            // and application_uninstalled, but nothing for the icon layout — so
            // a reorder made on the guest can only be noticed by asking again,
            // every time round, or the sidebar disagrees with the home screen
            // until something else happens to refresh it.
            //
            sortApps()
            prunePending()   // the list just changed; a row may have earned its exit
            reloadTablePreservingSelection()
            showInstalledPlaceholder(installedPlaceholderText)
            updateButtons()
        } catch is CancellationError {
            // Closing the inspector or ending a poll is not a failed device.
            return
        } catch {
            // A read already in flight when Power Off began is not a device fault.
            if !poweringDown {
                emulator.reportConnectionFailure(error, operation: "Refreshing apps")
            }
            // Prune here too. This path never touched `pending`, so a row whose
            // install failed because the device went away stayed on screen —
            // and the failing list read is exactly when that happens.
            prunePending()
            reloadTablePreservingSelection()
            // The reason rides along so a manual Refresh that fails says why,
            // instead of sitting on the same three words the boot wait shows.
            if !haveLoaded, pending.isEmpty {
                if case DeviceError.unavailable = error {
                    // Permanent and host-side: "Waiting" is the wrong frame and
                    // names no remedy.
                    showInstalledPlaceholder("App services are missing from this copy of Light Touch. Reinstall Light Touch.")
                } else {
                    showInstalledPlaceholder(emulator.connectionIssue?.summary ?? "Couldn’t update apps. Retrying…")
                }
                placeholder.toolTip = emulator.connectionIssue?.detail
            } else if haveLoaded {
                showStaleBanner()   // keep the list, mark it stale
            }
            // Also on the failure path: when usbmuxd dies the session goes away
            // and canManageApps flips false, but nothing told the inspector, so
            // "+" stayed enabled, opened a file picker, and the install failed
            // with an error blaming the guest for a host daemon that had died.
            updateButtons()
        }
    }

    /// True when the HOST side is gone rather than the guest — worth saying,
    /// because "device not responding" points the user at the wrong thing.
    private var usbUnavailable: Bool { !emulator.canManageApps }

    /// Subscribe to the guest's own install/uninstall notifications.
    private func startGuestNotifications() {
        guard let services = try? emulator.services else {
            notifications?.stop(); notifications = nil; notificationEndpoint = nil
            return
        }
        let endpoint = services.endpoint
        guard notificationEndpoint != endpoint else { return }
        notifications?.stop()
        notificationEndpoint = endpoint
        let watcher = NotificationProxy(clientSocket: endpoint.socket, udid: endpoint.udid, session: endpoint.session)
        notifications = watcher
        let emulator = self.emulator
        watcher.start(attachAllowed: {
            await MainActor.run {
                emulator.isRunning && !emulator.preparingDevice && emulator.usbConnected && !AppInstaller.isUsingDevice(emulator.instance.id)
                    && !emulator.isInstalling && !emulator.hasFileTransfer && !emulator.isReconnecting
            }
        }) {
            // Off the library's callback thread and onto ours.
            Task { @MainActor in
                guard (try? emulator.services.endpoint) == endpoint else { return }
                NotificationCenter.default.post(name: .ltmAppsChanged, object: emulator.instance.id)
            }
        }
    }

    // NotificationProxy cancels its own loops in its deinit, which is what
    // this releasing it triggers; nothing else here may touch main-actor state.
    deinit { loadTask?.cancel(); searchTask?.cancel() }

    private func showStaleBanner() {
        let when = AppsInspector.freshnessText(since: lastLoaded)
        if emulator.isPoweredOff { banner.stringValue = "Device powered off" }
        else if emulator.shuttingDown { banner.stringValue = "Device powering off…" }
        else if emulator.isReconnecting { banner.stringValue = "Reconnecting app services…" }
        else {
            banner.stringValue = usbUnavailable
                ? "USB connection unavailable"
                : emulator.connectionIssue?.summary ?? "Connecting to \(emulator.profile.shortName)…"
        }
        banner.toolTip = [emulator.connectionIssue?.detail, when]
            .compactMap { $0 }.joined(separator: "\n")
        banner.isHidden = false
        bannerHeight?.constant = 18
    }

    private func hideStaleBanner() {
        guard !banner.isHidden else { return }
        banner.isHidden = true
        bannerHeight?.constant = 0
    }

    /// Home-screen order when SpringBoard has told us one, and the *displayed*
    /// name otherwise — sorting by the reported name while showing the cached
    /// one is what made the list look unsorted and shuffle as metadata landed.
    private func sortApps() {
        // Sorted on a key, not a mix of two rules: comparing home-screen index
        // when both are known and names otherwise is not a consistent ordering,
        // and sort() is free to produce nonsense from one.
        apps.sort { a, b in
            let i = homeOrder.firstIndex(of: a.id) ?? .max
            let j = homeOrder.firstIndex(of: b.id) ?? .max
            if i != j { return i < j }
            return displayName(a).localizedCaseInsensitiveCompare(displayName(b)) == .orderedAscending
        }
    }

    private func displayName(_ app: InstalledApp) -> String {
        AppMetadataCache.shared.name(for: app.id) ?? app.name
    }

    private func showPlaceholder(_ text: String?) {
        placeholder.stringValue = text ?? ""
        placeholder.isHidden = (text == nil)
        let actions = AppsInspector.placeholderActions(message: text, searching: searching, haveLoaded: haveLoaded,
                                                       nothingListed: apps.isEmpty && pending.isEmpty, catalogFailed: catalogFailed)
        browseButton.isHidden = !actions.browseAndInstall
        installButton.isHidden = !actions.browseAndInstall
        installButton.isEnabled = emulator.canQueueInstall
        retryButton.isHidden = !actions.retry
        emptyActions.isHidden = !actions.group
    }

    /// Installed-list placeholders only — a no-op while the catalog results own
    /// the table, so the background poll can't clobber "No compatible apps
    /// found" with "Waiting for the device…" mid-search.
    private func showInstalledPlaceholder(_ text: String?) {
        guard !searching else { return }
        showPlaceholder(text)
    }

    private var installedPlaceholderText: String? { rows.installedPlaceholder(haveLoaded: haveLoaded) }

    /// Network downloads and waiting rows do not hold a device session.
    private var installing: Bool { AppInstaller.isUsingDevice(emulator.instance.id) || emulator.isInstalling }

    /// Apps with an uninstall in flight. Without this the row stayed, the
    /// buttons stayed live, and nothing said anything for up to two minutes —
    /// so the obvious thing to do was press Uninstall again.
    private var uninstalling: Set<String> = []
    private var removingApp: String?

    private func canUninstall(_ selection: [InstalledApp]) -> Bool { rows.canUninstall(selection) }
    private func removalStatus(for bundleID: String) -> String { rows.removalStatus(for: bundleID) }

    /// Any device operation of ours in flight.
    private var busyWithDevice: Bool { rows.busyWithDevice }

    /// See AppsDevice.readsSuppressed.
    private var readsSuppressed: Bool { device.readsSuppressed }

    private func updateButtons() {
        // A cached list can outlive the connection. Match the removal action's
        // reachability gate so stale rows never advertise a usable Uninstall.
        resumeButton.isHidden = !AppInstaller.isPaused(emulator.instance.id)
        if AppInstaller.isPaused(emulator.instance.id) {
            banner.stringValue = "Transfers paused"
            banner.isHidden = false
            bannerHeight?.constant = 28
        }
        addRemove.setEnabled(emulator.canQueueInstall, forSegment: 0)
        addRemove.setEnabled(haveLoaded && canUninstall(selectedApps), forSegment: 1)
    }

    private var selectedApps: [InstalledApp] { rows.selectedApps(tableView.selectedRowIndexes) }
    private var visibleApps: [InstalledApp] { rows.visibleApps }
    private func app(at row: Int) -> InstalledApp? { rows.app(at: row) }

    // MARK: - Actions

    @objc private func addOrRemove(_ sender: NSSegmentedControl) {
        sender.selectedSegment == 0 ? add() : remove(selectedApps)
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ipa")].compactMap { $0 }
        // Several at once: ready files install one at a time.
        panel.allowsMultipleSelection = true
        panel.message = "Choose decrypted .ipa files to install."
        panel.prompt = "Install"
        panel.beginSheetModal(for: view.window!) { [weak self] response in
            guard let self, response == .OK else { return }
            for url in panel.urls {
                AppInstaller.start(url, with: self.emulator, presenting: self.view.window)
            }
        }
    }

    private func remove(_ appsToRemove: [InstalledApp]) {
        guard canUninstall(appsToRemove) else { return }
        let alert = NSAlert()
        alert.messageText = appsToRemove.count == 1
            ? "Uninstall “\(displayName(appsToRemove[0]))”?"
            : "Uninstall \(appsToRemove.count) apps?"
        alert.informativeText = appsToRemove.count == 1
            ? "This removes the app and its data from the device."
            : "This removes the apps and their data from the device."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: view.window!) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            // An install can finish while this confirmation is open, leaving
            // reachability temporarily unknown until the next probe. The
            // already accepted removal must still enter the queue.
            guard self.emulator.isRunning, self.emulator.canManageApps else {
                AppInstaller.presentError(DeviceToolsError.failed("The \(emulator.profile.shortName) is unavailable. Try again when it reconnects."),
                                          self.view.window)
                return
            }
            let remaining = appsToRemove.filter { !self.uninstalling.contains($0.id) }
            guard !remaining.isEmpty else { return }
            for app in remaining { self.uninstalling.insert(app.id) }
            self.reloadTablePreservingSelection()
            self.updateButtons()
            AppInstaller.remove(remaining, with: self.emulator, presenting: self.view.window) { app in
                self.removingApp = app.id
                self.reloadTablePreservingSelection()
            } didRemove: { app in
                self.uninstalling.remove(app.id)
                self.removingApp = nil
                self.apps.removeAll { $0.id == app.id }
                self.reloadTablePreservingSelection()
            } didFinish: {
                for app in remaining { self.uninstalling.remove(app.id) }
                self.removingApp = nil
                self.reloadTablePreservingSelection()
                self.updateButtons()
            }
        }
    }

    @objc private func uninstallClicked(_ sender: NSMenuItem) {
        if let apps = sender.representedObject as? [InstalledApp] { remove(apps) }
        else if let app = sender.representedObject as? InstalledApp { remove([app]) }
    }

    @objc private func dismissInstallClicked(_ sender: NSMenuItem) {
        (sender.representedObject as? InstallJob)?.dismiss()
    }

    @objc private func cancelInstallClicked(_ sender: NSMenuItem) {
        (sender.representedObject as? InstallJob)?.cancel()
    }

    /// Install on ▸ <device>: this device's retained copy, queued on the other one.
    @objc private func installOnClicked(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? (file: URL, emulator: EmulatorController) else { return }
        AppInstaller.start(target.file, with: target.emulator, presenting: view.window)
    }

    @objc private func showInLegacyStoreClicked(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? InstalledApp else { return }
        // /app/<bundle_id> is a first-class route on the site (301s to the
        // canonical page); apps the archive doesn't know 404 there, which is
        // an honest answer.
        NSWorkspace.shared.open(CatalogClient.baseURL.appendingPathComponent("app/\(app.id)"))
    }

    @objc private func resumeInstallsClicked(_ sender: Any?) {
        Task {
            guard await emulator.deviceReady() else {
                AppInstaller.presentError(DeviceError.notAttached, view.window)
                return
            }
            emulator.deviceReachable = true
            AppInstaller.resume(emulator.instance.id)
            hideStaleBanner()
            reloadTablePreservingSelection()
            updateButtons()
        }
    }

    @objc private func refreshClicked(_ sender: Any?) {
        if searching { scheduleSearch(); return }
        Task { await loadOnce() }
    }

    // MARK: - Legacy Store (mode + search)

    private func filterChanged() {
        reloadTablePreservingSelection()
        if searching, !catalogFetched.isEmpty {
            showPlaceholder(AppsInspector.searchFinished(query: "", fetched: catalogFetched.count, shown: catalogResults.count))
        }
        updateButtons()
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        setMode(PaneMode(rawValue: sender.selectedSegment) ?? .installed)
    }

    private func setMode(_ newMode: PaneMode) {
        searchTask?.cancel()
        queries[mode] = searchField.stringValue
        mode = newMode
        searchField.stringValue = queries[newMode, default: ""]
        searchField.placeholderString = newMode == .store ? "Search Store" : "Search Installed Apps"
        modeControl.selectedSegment = newMode.rawValue
        filterButton.isEnabled = newMode == .store
        tableView.deselectAll(nil)
        reloadTablePreservingSelection()
        updateButtons()
        updateFooterVisibility()
        switch newMode {
        case .installed:
            showPlaceholder(installedPlaceholderText)
        case .store:
            scheduleSearch()
        }
    }

    /// Find / Search Apps: put the caret in the toolbar search field.
    func focusSearch() {
        guard let window = view.window ?? parent?.view.window else { return }
        if let split = window.contentViewController as? NSSplitViewController,
           let item = split.splitViewItem(for: self) { item.isCollapsed = false }
        window.contentView?.layoutSubtreeIfNeeded()
        // The field may be collapsed into a search icon or toolbar overflow.
        // AppKit owns attaching and expanding it before assigning focus.
        searchToolbarItem?.beginSearchInteraction()
    }

    @objc private func browseStore() { setMode(.store) }
    @objc private func installLocal() { add() }
    @objc private func searchEdited() {
        queries[mode] = searchField.stringValue
        if mode == .installed {
            reloadTablePreservingSelection()
            showPlaceholder(installedPlaceholderText)
        } else { scheduleSearch() }
    }

    /// Fetch what the Store view should show for the current search text —
    /// results for a query, the suggested (most-archived compatible) list for
    /// an empty one. No-op outside Store mode.
    private func scheduleSearch() {
        searchTask?.cancel()
        guard mode == .store else { return }
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        catalogFailed = false
        catalogFetched = []
        reloadTablePreservingSelection()
        // iPhone OS 1 predates the App Store: Legacy Store's suggested list is empty for it by definition,
        // which read as the store being broken. A search still runs (and says why each app can't install).
        // Replace the other mode's overlay before any debounce/network await.
        showPlaceholder(AppsInspector.searchStarting(query: query, iosVersion: emulator.iosVersion, haveResults: !catalogResults.isEmpty))
        guard AppsInspector.searchRuns(query: query, iosVersion: emulator.iosVersion) else {
            updateButtons()
            return
        }
        searchTask = Task { [weak self] in
            if !query.isEmpty {
                try? await Task.sleep(for: .milliseconds(300))   // debounce typing
            }
            guard let self, !Task.isCancelled else { return }
            // Only the response to what's in the field now may land — a slower
            // older query resolving late must not overwrite a newer list.
            let current = {
                self.mode == .store
                    && self.searchField.stringValue.trimmingCharacters(in: .whitespaces) == query
            }
            do {
                let results = try await CatalogClient.search(query, device: self.emulator.productType,
                                                             os: self.emulator.iosVersion)
                guard !Task.isCancelled, current() else { return }
                self.catalogFetched = results
                self.reloadTablePreservingSelection()
                self.showPlaceholder(AppsInspector.searchFinished(query: query, fetched: results.count, shown: self.catalogResults.count))
                self.fetchCatalogIcons(results)
            } catch {
                guard !Task.isCancelled, current() else { return }
                self.catalogFetched = []
                self.catalogFailed = true
                self.reloadTablePreservingSelection()
                self.showPlaceholder(AppsInspector.searchFailed(error, marketingName: self.emulator.profile.marketingName))
            }
            self.updateButtons()
        }
    }

    /// Warm the icon memo for these results, repainting each row as its icon
    /// lands. Content-addressed URLs, so a memo hit never goes stale.
    private func fetchCatalogIcons(_ results: [CatalogApp]) {
        for app in results {
            guard let url = app.iconURL,
                  CatalogClient.iconMemo.object(forKey: url.absoluteString as NSString) == nil
            else { continue }
            Task { [weak self] in
                guard await CatalogClient.icon(for: app) != nil else { return }
                self?.reloadCatalogRow(app.ipaID)
            }
        }
    }

    /// Icons landing together repaint once: a reload per icon rebuilt every row each time.
    private var catalogIconReload: Task<Void, Never>?
    private func reloadCatalogRow(_ ipaID: Int) {
        guard searching, catalogResults.contains(where: { $0.ipaID == ipaID }), catalogIconReload == nil else { return }
        catalogIconReload = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self else { return }
            catalogIconReload = nil
            if searching { reloadTablePreservingSelection() }
        }
    }

    fileprivate func catalogJob(for app: CatalogApp) -> InstallJob? { rows.catalogJob(for: app) }
    fileprivate func catalogState(of app: CatalogApp) -> CatalogRowState { rows.catalogState(of: app) }

    @objc fileprivate func catalogInstallClicked(_ sender: NSButton) {
        guard searching, catalogResults.indices.contains(sender.tag) else { return }
        let app = catalogResults[sender.tag]
        if let installed = apps.first(where: { $0.id == app.bundleID }) { launch(installed) }
        else { install(catalog: app) }
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        if searching {
            guard catalogResults.indices.contains(row) else { return }
            let item = NSMenuItem()
            item.representedObject = catalogResults[row]
            catalogDetailsClicked(item)
            return
        }
        launch(app(at: row))
    }

    /// Launch an installed app on the guest, exactly as tapping its icon would.
    private func launch(_ app: InstalledApp?) {
        guard let app, !busyWithDevice, !uninstalling.contains(app.id) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await emulator.launchApp(app.id)
            } catch is CancellationError {
                return
            } catch {
                let alert = NSAlert()
                if case AppLaunchError.locked = error {
                    alert.alertStyle = .informational
                    alert.messageText = "“\(displayName(app))” couldn’t open because the \(emulator.profile.shortName) is locked."
                    alert.informativeText = "Unlock it, then try again."
                } else {
                    alert.alertStyle = .warning
                    alert.messageText = "Couldn’t open “\(displayName(app))”"
                    if let launchError = error as? AppLaunchError {
                        alert.informativeText = launchError.message(for: emulator.profile)
                    } else {
                        logEvent("launch \(app.id): \(error.localizedDescription)")
                        alert.informativeText = AppLaunchError.failed.message(for: emulator.profile)
                    }
                }
                if let window = view.window { _ = await alert.beginSheetModal(for: window) }
                else { alert.runModal() }
            }
        }
    }

    @objc fileprivate func openClicked(_ sender: NSMenuItem) {
        launch(sender.representedObject as? InstalledApp)
    }

    @objc fileprivate func viewOnLegacyStoreClicked(_ sender: NSMenuItem) {
        guard let url = (sender.representedObject as? CatalogApp)?.appURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func catalogDetailsClicked(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? CatalogApp else { return }
        let canInstall = { [weak self] in
            guard let self else { return false }
            return self.emulator.canQueueInstall && self.catalogJob(for: app)?.isFinished != false
        }
        let sheet = CatalogDetailsViewController(app: app, device: emulator.productType, deviceOS: emulator.iosVersion, arch: emulator.guestArch,
                                                 installedVersion: apps.first { $0.id == app.bundleID }?.version,
                                                 canInstall: canInstall) { [weak self] copy in
            guard let self, canInstall() else { return }
            AppInstaller.startCatalog(copy, with: self.emulator, presenting: self.view.window)
        }
        presentAsSheet(sheet)
    }

    @objc fileprivate func installCatalogClicked(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? CatalogApp else { return }
        install(catalog: app)
    }

    @objc fileprivate func installSelectedCatalogClicked(_ sender: NSMenuItem) {
        for app in (sender.representedObject as? [CatalogApp]) ?? [] {
            install(catalog: app)
        }
    }

    private func install(catalog app: CatalogApp) {
        guard catalogState(of: app) == .installable else { return }
        // The job owns the whole pipeline — download included — so the row is
        // in `pending` (and visible in the installed list) from the first byte.
        AppInstaller.startCatalog(app, with: emulator, presenting: view.window)
    }
}

// MARK: - Search field

extension AppsInspectorViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { searchEdited() }
}

// MARK: - Context menu

extension AppsInspectorViewController: NSMenuDelegate {

    /// The Apps menu and a row's context menu, as LightTouchCore's AppsMenu lays them out.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let isMainMenu = menu !== tableView.menu
        let model = AppsMenu(rows: rows, isMainMenu: isMainMenu, row: isMainMenu ? tableView.selectedRow : tableView.clickedRow,
                             selection: tableView.selectedRowIndexes, inFrontWindow: view.window === NSApp.mainWindow,
                             retainedCopy: { [emulator] in IPALibrary.url(for: $0, device: emulator.instance) },
                             targets: (DeviceSessionHost.shared?.sessions ?? []).map { session in
                                 let entry = FirmwareCatalog.bundled.entry(id: session.instance.firmware)
                                 return AppsMenuTarget(title: entry.map { "\($0.marketingName) iOS \($0.version)" } ?? session.instance.name,
                                                       canQueueInstall: session.emulator.canQueueInstall,
                                                       isThisDevice: session.emulator === emulator, device: session.emulator)
                             })
        for item in model.items { menu.addItem(menuItem(item)) }
    }

    private func menuItem(_ item: AppsMenuItem) -> NSMenuItem {
        if item.isSeparator { return .separator() }
        let (action, object): (Selector?, Any?) = switch item.action {
        case .installApp: (#selector(MainWindowController.installApp(_:)), nil)
        case .importMedia: (#selector(MainWindowController.syncMedia(_:)), nil)
        case .resumeTransfers: (#selector(resumeInstallsClicked(_:)), nil)
        case .refresh: (#selector(refreshClicked(_:)), nil)
        case .install(let app): (#selector(installCatalogClicked(_:)), app)
        case .installBatch(let apps): (#selector(installSelectedCatalogClicked(_:)), apps)
        case .chooseVersion(let app): (#selector(catalogDetailsClicked(_:)), app)
        case .viewOnLegacyStore(let app): (#selector(viewOnLegacyStoreClicked(_:)), app)
        case .cancelInstall(let job): (#selector(cancelInstallClicked(_:)), job)
        case .dismissInstall(let job): (#selector(dismissInstallClicked(_:)), job)
        case .open(let app): (#selector(openClicked(_:)), app)
        case .uninstall(let apps): (#selector(uninstallClicked(_:)), apps.count == 1 ? apps[0] : apps)
        case .showInLegacyStore(let app): (#selector(showInLegacyStoreClicked(_:)), app)
        case .installOn(let file, let device): (#selector(installOnClicked(_:)), (file: file, emulator: device as! EmulatorController))
        case .none, .separator: (nil, nil)
        }
        let result = NSMenuItem(title: item.title, action: action, keyEquivalent: item.keyEquivalent)
        if item.shift { result.keyEquivalentModifierMask = [.shift, .command] }
        // The responder chain finds the window controller's own actions; the rest are this inspector's.
        switch item.action {
        case .installApp, .importMedia, .none: break
        default: result.target = self
        }
        result.representedObject = object
        result.isEnabled = item.isEnabled
        if let submenu = item.submenu {
            result.submenu = NSMenu()
            for entry in submenu { result.submenu!.addItem(menuItem(entry)) }
        }
        return result
    }
}

// MARK: - Table data

extension AppsInspectorViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        searching ? catalogResults.count : pending.count + visibleApps.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        if searching {
            guard catalogResults.indices.contains(row) else { return nil }
            return catalogCell(for: catalogResults[row], row: row)
        }
        if row < pending.count {
            let job = pending[row]
            // A finished job renders as an ORDINARY app row — icon, name, no
            // spinner, no percentage — even though it is still a pending entry
            // underneath. Two things fall out of that. It stops claiming
            // "Installing… 90%" for an app already sitting on the home screen
            // (instproxy's last progress callback is 90, then "Complete", so
            // that number was simply the last one anyone heard). And when the
            // real row finally replaces it, the two look the same, so the swap
            // that used to make the whole list flicker is now invisible.
            if job.isFinished, !job.isCancelled, !job.failed {
                let cell = appCell(tableView)
                cell.textField?.stringValue = job.name
                (cell.viewWithTag(Self.appSubtitleTag) as? NSTextField)?.stringValue =
                    job.bundleID ?? job.status
                AppRowCells.setIcon(job.bundleID.flatMap { AppMetadataCache.shared.icon(for: $0) },
                             on: cell.imageView)
                cell.imageView?.layer?.opacity = NSApp.isActive ? 1 : 0.5
                return cell
            }
            return progressCell(icon: pendingIcon(job), title: job.name,
                                subtitle: job.isCancelled ? "Cancelling…" : job.status,
                                fraction: job.downloadProgress, job: job)
        }
        guard let app = app(at: row) else { return nil }
        if uninstalling.contains(app.id) {
            return progressCell(icon: AppMetadataCache.shared.icon(for: app.id),
                                title: displayName(app), subtitle: removalStatus(for: app.id))
        }
        let cell = appCell(tableView)
        cell.textField?.stringValue = displayName(app)
        (cell.viewWithTag(Self.appSubtitleTag) as? NSTextField)?.stringValue =
            app.version
        AppRowCells.setIcon(AppMetadataCache.shared.icon(for: app.id), on: cell.imageView)
        // AppKit only dims a *selected* row when the window resigns key,
        // leaving every other icon at full strength — inconsistent with the
        // rest of the sidebar, which dims as a whole. Set explicitly instead
        // of relying on that per-row behavior; refreshed by the app-active
        // observers below whenever it changes with no reload otherwise due.
        cell.imageView?.layer?.opacity = NSApp.isActive ? 1 : 0.5
        cell.toolTip = "\(app.id)\(app.version.isEmpty ? "" : " — \(app.version)")"
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    // Every row selects, pending installs included — an unselectable row in a
    // source list reads as broken. What a pending row can't do (uninstall) is
    // decided where the buttons are enabled, not by refusing the selection.

    // MARK: Dragging — reorder within, files/links out, .ipas in

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        if searching {
            // A Store row travels as its Legacy Store link, plus a private
            // payload the device view recognizes for drag-to-install.
            guard catalogResults.indices.contains(row) else { return nil }
            let app = catalogResults[row]
            let item = NSPasteboardItem()
            if let url = app.appURL { item.setString(url.absoluteString, forType: .URL) }
            if app.incompatibility == nil, let payload = try? JSONEncoder().encode(app) {
                item.setData(payload, forType: .ltmCatalogApp)
            }
            return item
        }
        guard let app = app(at: row) else { return nil }
        // An installed row travels as its bundle id (the internal reorder
        // token) and, when the library kept the bytes, the .ipa file itself —
        // draggable straight into the Finder.
        let item = NSPasteboardItem()
        item.setString(app.id, forType: .string)
        if let file = IPALibrary.url(for: app.id, device: emulator.instance) {
            item.setString(file.absoluteString, forType: .fileURL)
        }
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        if info.draggingSource as? NSTableView !== tableView {
            // From outside: an .ipa to install, if the device can take one.
            guard emulator.canReachDevice, !Self.droppedIPAs(info).isEmpty else { return [] }
            tableView.setDropRow(-1, dropOperation: .on)   // the list as a whole
            return .copy
        }
        // Reorder: only the installed list, only against a known home-screen
        // order, never during an install (the SpringBoard write is one more
        // lockdown session the install can't afford), and one row at a time
        // (moveOnHomeScreen takes one id).
        guard !searching, queries[.installed, default: ""].isEmpty, !homeOrder.isEmpty, !installing,
              info.draggingPasteboard.pasteboardItems?.count == 1,
              operation == .above, row >= pending.count else { return [] }
        return .move
    }

    private static func droppedIPAs(_ info: NSDraggingInfo) -> [URL] {
        DroppedFiles.files(info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? [], .ipa)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let ipas = Self.droppedIPAs(info)
        if !ipas.isEmpty, info.draggingSource as? NSTableView !== tableView {
            ipas.forEach { AppInstaller.start($0, with: emulator, presenting: view.window) }
            return true
        }
        guard let id = info.draggingPasteboard.string(forType: .string) else { return false }
        // Dropping above row N means "put it where the app now at N sits", and
        // past the last row means the end. The bundle ID travels rather than the
        // index, so the answer survives the list reloading mid-drag.
        let target = app(at: row)?.id
        // Dropping an app on its OWN top edge is the no-op AppKit normally
        // treats as "nothing happened". Here `target` was the dragged app
        // itself, which the remove() below takes out of `apps` — so the
        // firstIndex lookup found nothing, the ?? fired, and the app was sent
        // to the END of the home screen. That got written to SpringBoard, so a
        // few pixels of accidental drag really moved the icon to the last page.
        guard target != id else { return false }

        // Move it locally first: the device round trip is slow enough that a row
        // snapping back and then jumping looks like a failed drag. Moved with
        // the table's own row animation rather than reloadData() — a reload in
        // the middle of a drop is what made this look homemade.
        if let from = apps.firstIndex(where: { $0.id == id }) {
            let app = apps.remove(at: from)
            let to = target.flatMap { t in apps.firstIndex { $0.id == t } } ?? apps.count
            apps.insert(app, at: to)
            tableView.beginUpdates()
            tableView.moveRow(at: pending.count + from, to: pending.count + to)
            tableView.endUpdates()
        }

        Task {
            do {
                // Adopt the order SpringBoard ACCEPTED. Dropping it meant the
                // next list read fell back to the pre-drag `homeOrder` and
                // re-sorted the sidebar back to where it started, while the
                // device kept the new arrangement.
                homeOrder = try await emulator.services.moveOnHomeScreen(id, before: target, profile: emulator.profile)
            } catch {
                AppInstaller.presentError(error, view.window)
            }
            await loadOnce()
        }
        return true
    }

    private func appCell(_ tableView: NSTableView) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier("appCell")
        if let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            return cell
        }
        let cell = NSTableCellView()
        cell.identifier = id
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        image.wantsLayer = true
        image.layer?.cornerRadius = 6
        image.layer?.cornerCurve = .circular
        image.layer?.masksToBounds = true
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.maximumNumberOfLines = 1
        text.cell?.wraps = false
        // A narrow inspector truncates app names; hovering shows the whole one.
        text.allowsExpansionToolTips = true
        text.translatesAutoresizingMaskIntoConstraints = false
        let subtitle = NSTextField(labelWithString: "")
        subtitle.tag = Self.appSubtitleTag
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitle.lineBreakMode = .byTruncatingMiddle   // bundle ids differ at both ends
        subtitle.allowsExpansionToolTips = true
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        [image, text, subtitle].forEach(cell.addSubview)
        cell.imageView = image
        cell.textField = text
        cell.backgroundStyle = .lowered
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 32),
            image.heightAnchor.constraint(equalToConstant: 32),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.bottomAnchor.constraint(equalTo: cell.centerYAnchor, constant: 0),
            subtitle.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            subtitle.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 1),
        ])
        return cell
    }

    private static let appSubtitleTag = 8

    /// A Legacy Store result, or its transfer or removal in flight (LightTouchCore's catalogRow decides which).
    private func catalogCell(for app: CatalogApp, row: Int) -> NSTableCellView {
        switch rows.catalogRow(for: app) {
        case .progress(let subtitle, let fraction, let job):
            return progressCell(icon: catalogIcon(app), title: app.name, subtitle: subtitle, fraction: fraction, job: job)
        case .result(let button, let enabled):
            return AppRowCells.catalogCell(app, icon: catalogIcon(app), button: button, enabled: enabled, row: row,
                                           target: self, action: #selector(catalogInstallClicked(_:)))
        }
    }

    /// The catalog's icon for a result, if it has arrived.
    private func catalogIcon(_ app: CatalogApp) -> NSImage? {
        app.iconURL.flatMap { CatalogClient.iconMemo.object(forKey: $0.absoluteString as NSString) }
    }

    /// The best icon we have for a job that hasn't landed yet: the catalog's
    /// (already fetched for the search row), else a cached one for the same
    /// bundle id (reinstalls), else the generic placeholder.
    private func pendingIcon(_ job: InstallJob) -> NSImage? {
        if let url = job.catalogIconURL,
           let memo = CatalogClient.iconMemo.object(forKey: url.absoluteString as NSString) {
            return memo
        }
        return job.bundleID.flatMap { AppMetadataCache.shared.icon(for: $0) }
    }

    private func progressCell(icon: NSImage?, title: String, subtitle: String,
                              fraction: Double? = nil, job: InstallJob? = nil) -> NSTableCellView {
        AppRowCells.progressCell(icon: icon, title: title, subtitle: subtitle, fraction: fraction, job: job) { [weak self] in
            self?.resumeInstallsClicked(nil)
        }
    }

}
