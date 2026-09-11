// Created by Sam on 2026-08-05.

import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    
    private var windowController: MainWindowController?
    private var emulator: EmulatorController?
    private var settingsController: SettingsWindowController?
    private var helpController: NSWindowController?
    private var awaitingTermination = false
    private var terminationBackstop: Task<Void, Never>?

    /// NSApplication's deferred quit runs a nested modal loop. Invoking it
    /// inside a main-queue callback occupies that serial queue until quit
    /// finishes, starving the Swift main-actor tasks needed to finish it.
    /// A run-loop timer invokes AppKit without holding the dispatch queue.
    /// System logout still uses applicationShouldTerminate's native reply.
    static func requestTermination() {
        guard (NSApp.delegate as? AppDelegate)?.awaitingTermination != true else { return }
        let timer = Timer(timeInterval: 0, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard (NSApp.delegate as? AppDelegate)?.awaitingTermination != true else { return }
                NSApp.terminate(nil)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc func quit(_ sender: Any?) { Self.requestTermination() }

    @objc func showSettings(_ sender: Any?) {
        guard let emulator else { return }
        if settingsController == nil { settingsController = SettingsWindowController(emulator: emulator) }
        settingsController?.showWindow(sender)
    }

    @objc func showHelp(_ sender: Any?) {
        if helpController == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
                styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Light Touch Help"
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 360, height: 300)
            window.setFrameAutosaveName("Help")
            let scroll = NSScrollView(frame: window.contentView!.bounds)
            scroll.hasVerticalScroller = true
            scroll.autoresizingMask = [.width, .height]
            let text = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
            text.isEditable = false
            text.isSelectable = true
            text.isVerticallyResizable = true
            text.isHorizontallyResizable = false
            text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            text.usesFindBar = true
            text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            text.textContainer?.heightTracksTextView = false
            text.textContainerInset = NSSize(width: 24, height: 20)
            text.font = .systemFont(ofSize: 14)
            text.string = Bundle.main.url(forResource: "Help", withExtension: "txt")
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "Help is missing from this build."
            text.setAccessibilityLabel("Light Touch Help")
            scroll.documentView = text
            text.sizeToFit()
            window.contentView!.addSubview(scroll)
            window.center()
            helpController = NSWindowController(window: window)
        }
        helpController?.showWindow(sender)
        helpController?.window?.makeKeyAndOrderFront(sender)
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let windowController else { return nil }
        let menu = NSMenu()
        for (title, action) in [("Home", #selector(MainWindowController.deviceHome(_:))),
                                ("Lock", #selector(MainWindowController.deviceLock(_:))),
                                ("Restart…", #selector(MainWindowController.deviceReset(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = windowController
            menu.addItem(item)
        }
        return menu
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // AppKit injects AutoFill, Start Dictation and Emoji & Symbols into the
        // Edit menu, and a Tab Bar section into View. All of them are dead here:
        // there is no editable text and the app is single-window. These defaults
        // are the only supported way to decline them, and must be set before the
        // menu is built.
        UserDefaults.standard.register(defaults: [
            "NSDisabledDictationMenuItem": true,
            "NSDisabledCharacterPaletteMenuItem": true,
        ])
        NSWindow.allowsAutomaticWindowTabbing = false

        MainMenuBuilder.install()
        #if DEBUG
        SpringBoardIcons.selfCheck()
        #endif
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        do { try Bundled.requireStorage() }
        catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Couldn’t open device storage"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            Self.requestTermination()
            return
        }
        do { try NativeLogging.start() }
        catch { logEvent("logging: native output capture unavailable: \(error.localizedDescription)") }
        let options = LaunchOptions.resolved()

        // Report missing device files up front. Booting without them dies deep
        // inside the dylib on the QEMU thread with no error the app can show.
        let missing = options.missingAssets()
        if !missing.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Missing device files"
            alert.informativeText = """
            LightTouchMac could not find these required files:

            \(missing.joined(separator: "\n"))

            Point --files-root or the LTM_FILES environment variable at a valid \
            qemu-ios-files directory.
            """
            alert.runModal()
            Self.requestTermination()
            return
        }

        let emulator = EmulatorController(options: options)
        // Start before showing the window: the inspector checks the usbmux
        // session in its viewDidLoad, which runs during showWindow.
        emulator.start()

        let controller = MainWindowController(emulator: emulator)
        controller.showWindow(nil)

        self.emulator = emulator
        self.windowController = controller
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminationBackstop?.cancel()
        emulator?.stop()
    }

    /// On quit: guard an in-flight install, then shut the guest down so it
    /// unmounts. beginCleanShutdown requires explicit guest confirmation;
    /// native halt without PMU power-off remains a known limitation.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if awaitingTermination { return .terminateLater }
        if windowController?.finishRecordingBeforeQuit() == true { return .terminateCancel }
        guard let emulator else { return .terminateNow }

        // Queued installs count too. isInstalling is set only around the install
        // that is executing; jobs waiting their turn are parked on the previous
        // job's task, so quitting with three .ipas queued used to take no notice
        // and drop them without a word.
        if emulator.isInstalling || AppInstaller.hasPendingWork {
            let alert = NSAlert()
            alert.messageText = "An app install is in progress"
            alert.informativeText = "Quitting now will leave an app half-installed on the device, "
                + "and cancel any others still queued. Quit anyway?"
            alert.addButton(withTitle: "Quit Anyway")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else {
                emulator.cancelFactoryReset()   // this quit was the erase; call it off
                return .terminateCancel
            }
            AppInstaller.cancelPendingWork()
            // Falls through to the SAME shutdown as any other quit. It used to
            // return .terminateNow, on the reasoning that a half-finished
            // install is not a clean state to snapshot — true, and irrelevant
            // to the flush. Skipping the flush threw away every app installed
            // earlier in the session as well as the one in flight.
        }

        guard !emulator.isDead, !emulator.isPoweredOff else { return .terminateNow }

        awaitingTermination = true
        let reply = { [weak self] in
            // A guard can complete synchronously. Reply only after this
            // delegate invocation has returned terminateLater to AppKit.
            DispatchQueue.main.async {
                guard let self, self.awaitingTermination else { return }
                self.awaitingTermination = false
                self.terminationBackstop?.cancel()
                self.terminationBackstop = nil
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        let backstop = EmulatorController.cleanShutdownBudget
            + (EmulatorController.resumeOnLaunch ? EmulatorController.quitSnapshotBudget : 0)
        terminationBackstop = Task {
            do { try await Task.sleep(for: .seconds(backstop)) } catch { return }
            logEvent("quit: shutdown did not finish in time — quitting anyway")
            reply()
        }

        // Exactly ONE of these two runs, and that is the whole point.
        //
        // Both make the session durable, by opposite means. The snapshot freezes
        // RAM while flash stays where it is; the powerdown makes the guest
        // unmount, which pushes RAM's HFS+ catalog INTO flash. Doing the save
        // and then the powerdown — which is what this used to ask for — leaves
        // the snapshot describing a filesystem that has since moved on, i.e.
        // exactly the stale-RAM-over-newer-flash corruption the snapshot code
        // spends its comments warning about. So: save if resume is on, and fall
        // back to unmounting only if the save did not happen.
        if EmulatorController.resumeOnLaunch, !emulator.isInstalling, !AppInstaller.hasPendingWork {
            emulator.beginQuitSnapshot { saved in
                if saved { reply() } else { emulator.beginCleanShutdown { _ in reply() } }
            }
        } else {
            emulator.beginCleanShutdown { _ in reply() }
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Bring the device window back on a Dock click.
    ///
    /// Closing it is normally the same as quitting — but not while Settings is
    /// open, because then it isn't the last window and the app stays alive with
    /// the emulator running and nothing on screen. There is no menu item that
    /// recreates it and the Window menu only lists windows that exist, so the
    /// app was unrecoverable short of ⌘Q. Checked on the window rather than
    /// AppKit's hasVisibleWindows, which counts Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if windowController?.window?.isVisible != true { windowController?.showWindow(nil) }
        return true
    }
    
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
