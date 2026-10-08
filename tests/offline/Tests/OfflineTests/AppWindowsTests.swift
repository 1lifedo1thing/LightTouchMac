import AppKit
import HostRuntime
import ObjectiveC
import SwiftUI
import Testing

@testable import AppViews
@testable import LightTouchCore

extension SharedState {
    /// Sheets, panels and windows of the app, laid out offscreen (never ordered in).
    @Suite(.serialized) struct AppWindowsTests {
        init() {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
        }

        static func descendants(_ view: NSView) -> [NSView] {
            var children = view.subviews
            if let stack = view as? NSStackView {
                for child in stack.arrangedSubviews where !children.contains(where: { $0 === child }) {
                    children.append(child)
                }
            }
            return [view] + children.flatMap(descendants)
        }

        /// Windows opt out of state restoration (no restoration class, no autosave) unless named; a named window keeps
        /// only its frame: the first has nothing to apply, a later one with the same name opens where it was left.
        /// LightTouchApplication's own restoration overrides need their own app process and aren't checked here;
        /// RestorationDefaultsTests has the process-only defaults.
        @Test func windowRestorationPolicy() {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.isRestorable = true
            WindowRestorationPolicy.configure(window)
            #expect(!window.isRestorable && window.restorationClass == nil && window.frameAutosaveName.isEmpty)
            let name = "ltm-frame-test-" + UUID().uuidString
            defer { UserDefaults.standard.removeObject(forKey: "NSWindow Frame " + name) }
            let first = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .resizable],
                backing: .buffered,
                defer: false
            )
            #expect(
                !WindowRestorationPolicy.configure(first, frameAutosaveName: name) && first.frameAutosaveName == name
                    && !first.isRestorable
            )
            let moved = NSRect(x: 123, y: 77, width: 500, height: 410)
            first.setFrame(moved, display: false)
            first.saveFrame(usingName: name)
            let second = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .resizable],
                backing: .buffered,
                defer: false
            )
            #expect(
                WindowRestorationPolicy.configure(second, frameAutosaveName: name) && second.frame.size == moved.size,
                "saved frame not applied: \(second.frame)"
            )
        }

        /// The Debug Port sheet lays out at a real size with its commands. The menu items and the sheet's text are
        /// LightTouchCoreTests' DeviceSettingsMenuTests.
        @Test func debugPortSheet() {
            let lldb = "lldb -o 'gdb-remote 127.0.0.1:4321' KERNELCACHE"
            let sheet = NSHostingView(
                rootView: DebugPortView(
                    shortName: "iPod",
                    port: 4321,
                    lldbWithSymbols: lldb,
                    enabled: true,
                    onToggle: {},
                    onDone: {}
                )
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
                styleMask: [.titled],
                backing: .buffered,
                defer: true
            )
            window.contentView = sheet
            sheet.setFrameSize(sheet.fittingSize)
            sheet.layoutSubtreeIfNeeded()
            #expect(
                sheet.fittingSize.width >= 500 && sheet.fittingSize.height > 250,
                "debug port sheet \(sheet.fittingSize)"
            )
        }

        /// The Help window over the bundled Help.txt: its topics in a sidebar, the chosen topic's text, [Device] renamed
        /// keeping the topic, scrolling and Find. The topics and the text's audit are HelpTopicTests'.
        @Test func helpWindow() throws {
            let whole = try String(
                contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                    .appendingPathComponent("../../../../LightTouchMac/Help.txt").standardizedFileURL,
                encoding: .utf8
            )
            let help = HelpWindowController(text: whole)
            let window = help.window!
            help.show(deviceName: "iPad")
            let topics = HelpTopic.topics(whole)
            let titles = topics.map(\.title)
            let list = try #require(Self.descendants(window.contentView!).compactMap { $0 as? NSTableView }.first)
            let text = help.text
            #expect(list.numberOfRows == topics.count && list.selectedRow == 0)
            #expect(!text.isEditable && text.isSelectable && text.usesFindBar)
            func show(_ title: String) -> String {
                list.selectRowIndexes([titles.firstIndex(of: title)!], byExtendingSelection: false)
                return text.string
            }
            let capture = show("Screenshots and recordings")
            #expect(
                capture.hasPrefix("Screenshots and recordings\n") && capture.contains("Recordings include device audio")
                    && !capture.contains("Physical Size")
            )
            let files = show("Device files")
            #expect(
                files.contains("Show iPad Files") && files.contains("Copy to iPad") && !files.contains("[Device]"),
                "\(files)"
            )
            help.show(deviceName: "iPod")
            #expect(
                text.string.contains("Show iPod Files") && list.selectedRow == titles.firstIndex(of: "Device files"),
                "a new name keeps the topic"
            )
            window.setContentSize(NSSize(width: 560, height: 300))
            window.contentView!.layoutSubtreeIfNeeded()
            _ = show("Screenshots and recordings")
            text.layoutManager!.ensureLayout(for: text.textContainer!)
            text.sizeToFit()
            let scroll = text.enclosingScrollView!
            #expect(
                scroll.hasVerticalScroller && text.frame.height > scroll.contentSize.height
                    && text.textContainer!.widthTracksTextView
            )
            #expect(!window.isVisible)
            window.close()
        }

        /// The Carrier panel against a fake modem: Applying… with a spinner until the modem reports the new carrier and
        /// PLMN, not before or after; the SMS field is multiline. The model's rules are CarrierPanelModelTests'.
        @Test func carrierPanel() async throws {
            final class Modem: CarrierBackend {
                var carrierSettings = CarrierSettings()
                var reported = CarrierSettings()
                func setCarrierSettings(_ settings: CarrierSettings) -> Bool {
                    carrierSettings = settings
                    return true
                }
                func modem(_ property: String, _ value: String, done: @escaping @MainActor (Bool) -> Void) {
                    done(true)
                }
                func modemStatus(_ done: @escaping @MainActor (ModemStatus?) -> Void) {
                    done(
                        ModemStatus(
                            json:
                                #"{"carrier": "\#(reported.carrier)", "mcc-mnc": "\#(reported.mccMNC)", "registered": true, "sim-present": true}"#
                        )
                    )
                }
            }
            let modem = Modem()
            let model = CarrierPanelModel(backend: modem)
            let hosting = NSHostingView(rootView: CarrierPanel(model: model))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 760),
                styleMask: [.titled],
                backing: .buffered,
                defer: true
            )
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = hosting
            func settle() {
                for _ in 0..<5 {
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
                    hosting.layoutSubtreeIfNeeded()
                }
            }
            model.poll()
            #expect(!model.applyingNetwork, "applying before any change")
            model.carrierName = "Fictional"
            model.applyNetwork()
            model.poll()
            #expect(model.applyingNetwork, "no progress while the modem still reports the old carrier")
            settle()
            #expect(Self.descendants(hosting).contains { $0 is NSProgressIndicator }, "no spinner while applying")
            modem.reported = modem.carrierSettings
            model.poll()
            #expect(!model.applyingNetwork, "still applying once the modem reports it")
            func messageField() -> NSView? {
                Self.descendants(hosting).first {
                    ($0 as? NSTextField)?.stringValue == model.smsText || ($0 as? NSTextView)?.string == model.smsText
                }
            }
            model.smsText = "x"
            settle()
            let one = messageField()?.frame.height
            model.smsText = (1...5).map { "line \($0)" }.joined(separator: "\n")
            settle()
            let five = messageField()?.frame.height
            #expect(
                one.map { $0 >= 40 } == true && five.map { $0 > one! + 10 } == true,
                "the message field isn't multiline: \(String(describing: one)) -> \(String(describing: five))"
            )
        }

        /// The web proxy sheet: Cancel and OK (the default), the choices enabling each other, the archive date kept in the
        /// local calendar day (west and east of UTC, across a DST change) and the transient status fitting the 300-pt
        /// panel. The per-device proxy files are WebProxyConfigurationTests'.
        @Test(arguments: ["America/New_York", "America/Los_Angeles", "Asia/Tokyo"]) func proxySheet(zone: String) throws
        {
            let saved = NSTimeZone.default
            NSTimeZone.default = TimeZone(identifier: zone)!
            defer { NSTimeZone.default = saved }
            for mode in [WebProxyConfiguration.Mode.off, .direct, .archive] {
                let initial = WebProxyConfiguration(mode: mode, archiveDate: "20090909")
                let panel = ProxySettingsView(configuration: initial, status: .ready, profile: .n72)
                var answers: [Bool] = []
                let sheet = ProxySettingsView.sheet(panel) { answers.append($0) }
                let sheetButtons = Self.descendants(sheet.contentView!).compactMap { $0 as? NSButton }.filter {
                    $0.title == "OK" || $0.title == "Cancel"
                }
                try #require(sheetButtons.map(\.title) == ["Cancel", "OK"])
                #expect(sheetButtons[1].keyEquivalent == "\r" && sheetButtons[0].keyEquivalent == "\u{1b}")
                sheetButtons[0].performClick(nil)
                sheetButtons[1].performClick(nil)
                #expect(answers == [false, true])
                #expect(panel.configuration == initial)
                let all = Self.descendants(panel)
                let buttons = all.compactMap { $0 as? NSButton }
                let enabled = try #require(buttons.first { $0.title == "Use HTTP proxy" })
                let archive = try #require(buttons.first { $0.title == "Browse the Internet Archive" })
                let date = try #require(all.compactMap { $0 as? NSDatePicker }.first)
                let components = Calendar.current.dateComponents([.year, .month, .day, .hour], from: date.dateValue)
                #expect(
                    components.year == 2009 && components.month == 9 && components.day == 9 && components.hour == 0,
                    "archive date shifted in \(zone): \(date.stringValue)"
                )
                #expect(archive.isEnabled == (mode != .off))
                #expect(date.isEnabled == (mode == .archive))
                let readyHeight = panel.frame.height
                for status in [WebProxyStatus.waiting, .applying, .failed, .ready] {
                    panel.updateStatus(status)
                    panel.layoutSubtreeIfNeeded()
                    let visible = Self.descendants(panel).filter { !$0.isHiddenOrHasHiddenAncestor }
                    let labels = visible.compactMap { ($0 as? NSTextField)?.stringValue }
                    if let message = status.message(for: .n72) {
                        #expect(labels.contains(message), "\(labels)")
                    } else {
                        #expect(!labels.contains(where: { $0.contains("proxy…") || $0.contains("Try again") }))
                    }
                    #expect(panel.frame.height >= readyHeight)
                    #expect(panel.frame.width == 300)
                    #expect(
                        sheet.contentView!.frame.height >= panel.frame.height + 60,
                        "the sheet grows with its panel"
                    )
                    for view in visible where view is NSControl {
                        let rect = view.convert(view.bounds, to: panel)
                        #expect(
                            rect.minX >= -3 && rect.maxX <= panel.bounds.width + 3,
                            "horizontal overflow: \(view) \(rect)"
                        )
                        #expect(
                            rect.minY >= -3 && rect.maxY <= panel.bounds.height + 3,
                            "vertical overflow: \(view) \(rect), height \(panel.bounds.height)"
                        )
                    }
                }
                if enabled.state == .off { enabled.performClick(nil) }
                #expect(archive.isEnabled)
                if archive.state == .off { archive.performClick(nil) }
                #expect(date.isEnabled && panel.configuration.mode == .archive)
                #expect(panel.configuration.archiveDate == "20090909")
                enabled.performClick(nil)
                #expect(panel.configuration.mode == .off && !date.isEnabled)
                enabled.performClick(nil)  // turning the proxy off keeps the archive date for next time
                #expect(panel.configuration.mode == .archive)
                let calendar = date.calendar!
                date.dateValue = calendar.date(from: DateComponents(year: 2009, month: 11, day: 1))!
                #expect(panel.configuration.archiveDate == "20091101")
                date.dateValue = calendar.date(byAdding: .day, value: 1, to: date.dateValue)!
                #expect(panel.configuration.archiveDate == "20091102", "day stepping across daylight saving time")
            }
        }

        /// The main pane's console split through the view: the toggle, drags and double-clicks on the bar (detents,
        /// collapse threshold, minimum), a short window squeezing the console and giving it back, per-name persistence,
        /// the log sources and the bar's appearance over the gradient. The layout's numbers are ConsoleSplitLayoutTests'.
        @Test func consoleSplit() async throws {
            typealias L = ConsoleSplitLayout
            // Final geometry, not animation timing: the real Reduce Motion path (a sleeping display pauses the animator).
            let motionGetter = class_getInstanceMethod(
                NSWorkspace.self,
                #selector(getter: NSWorkspace.accessibilityDisplayShouldReduceMotion)
            )!
            let motionless: @convention(block) (AnyObject) -> Bool = { _ in true }
            let replacement = imp_implementationWithBlock(motionless)
            let previous = method_setImplementation(motionGetter, replacement)
            defer {
                method_setImplementation(motionGetter, previous)
                imp_removeBlock(replacement)
            }
            let suite = "ltm-console-split-check-\(getpid())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let top = NSView()
            let split = ConsoleSplitView(top: top, autosaveName: "view", defaults: defaults)
            split.appearance = NSAppearance(named: .aqua)
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600 + ConsoleBar.height))
            split.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(split)
            let hostHeight = host.heightAnchor.constraint(equalToConstant: 0)
            NSLayoutConstraint.activate([
                host.widthAnchor.constraint(equalToConstant: 800), hostHeight,
                split.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                split.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                split.topAnchor.constraint(equalTo: host.topAnchor),
                split.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
            func resize(_ height: CGFloat) {
                hostHeight.constant = height + ConsoleBar.height
                host.layoutSubtreeIfNeeded()
            }
            resize(600)
            let bar = split.bar
            let log = split.log
            #expect(
                log.frame.height == 0 && bar.frame.minY == 0 && top.frame.height == 600,
                "collapsed: bar pinned at the bottom"
            )
            #expect(
                bar.filter.isHidden && bar.clearButton.isHidden && !bar.toggleButton.isHidden,
                "collapsed bar shows only the toggle"
            )
            #expect(bar.toggleButton.state == .off && bar.toggleButton.toolTip == "Show Console (⇧⌘Y)", "toggle off")
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-console-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let log1 = dir.appendingPathComponent("serial.log")
            try Data("boot\n".utf8).write(to: log1)
            split.sources = [log1, dir.appendingPathComponent("usbmuxd.log")]
            #expect(
                bar.source.itemTitles == ["Device Console", "USB"] && log.url == log1,
                "sources: \(bar.source.itemTitles)"
            )
            #expect(
                ["app.log", "native.log", "other.log"].map {
                    ConsoleSplitView.title(for: URL(fileURLWithPath: "/l/" + $0))
                }
                    == ["Light Touch", "Emulator", "other.log"],
                "plain log names"
            )
            // The choice follows the log across devices: a new list keeps USB selected.
            bar.source.selectItem(withTitle: "USB")
            bar.source.sendAction(bar.source.action, to: bar.source.target)
            split.sources = [
                URL(fileURLWithPath: "/elsewhere/serial.log"), URL(fileURLWithPath: "/elsewhere/usbmuxd.log"),
            ]
            #expect(
                bar.source.titleOfSelectedItem == "USB" && log.url?.path == "/elsewhere/usbmuxd.log",
                "choice follows the log"
            )
            split.sources = [log1, dir.appendingPathComponent("usbmuxd.log")]
            bar.source.selectItem(at: 0)
            bar.source.sendAction(bar.source.action, to: bar.source.target)
            // Over the device's gradient the bar is dark in a light window, the console under it is not.
            #expect(
                bar.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua,
                "no gradient: the bar follows the system"
            )
            bar.overGradient = true
            #expect(
                bar.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
                "over the gradient the bar is dark"
            )
            #expect(log.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua, "only the bar is dark")
            func settle() async throws {
                try await Task.sleep(for: .milliseconds(400))
                split.layoutSubtreeIfNeeded()
            }

            bar.toggleButton.performClick(nil)
            try await settle()
            #expect(
                !split.layout.isCollapsed && log.frame.height == 200 && !log.isHidden,
                "toggle shows at 200, got \(log.frame.height)"
            )
            #expect(
                bar.toggleButton.state == .on && !bar.filter.isHidden
                    && bar.toggleButton.toolTip == "Hide Console (⇧⌘Y)",
                "toggle on"
            )
            #expect(L.load("view", from: defaults) == split.layout, "toggle persists")

            // Drags on the bar, from 200: up 62 is 262, within 10 of the middle (100+440)/2 = 270.
            func drag(_ dy: CGFloat, clicks: Int = 1) {
                func event(_ type: NSEvent.EventType, _ y: CGFloat) -> NSEvent {
                    NSEvent.mouseEvent(
                        with: type,
                        location: NSPoint(x: 400, y: y),
                        modifierFlags: [],
                        timestamp: 0,
                        windowNumber: 0,
                        context: nil,
                        eventNumber: 0,
                        clickCount: clicks,
                        pressure: 1
                    )!
                }
                bar.mouseDown(with: event(.leftMouseDown, 300))
                bar.mouseDragged(with: event(.leftMouseDragged, 300 + dy / 2))
                bar.mouseDragged(with: event(.leftMouseDragged, 300 + dy))
                bar.mouseUp(with: event(.leftMouseUp, 300 + dy))
                split.layoutSubtreeIfNeeded()
            }
            drag(62)
            #expect(log.frame.height == 270, "drag to 262 snaps to 270, got \(log.frame.height)")
            drag(-40)
            #expect(log.frame.height == 230, "drag to 230 stays, got \(log.frame.height)")
            drag(180)
            #expect(log.frame.height == 410, "drag to 410 stays, got \(log.frame.height)")
            drag(-400)
            #expect(
                split.layout.isCollapsed && log.frame.height == 0 && split.layout.height == 410,
                "drag below threshold collapses, keeps 410"
            )
            #expect(L.load("view", from: defaults) == L(height: 410, isCollapsed: true), "drag persists")
            drag(150)
            #expect(!split.layout.isCollapsed && log.frame.height == 150, "drag up from collapsed opens at the drag")
            drag(-60)
            #expect(log.frame.height == 100, "between threshold and minimum clamps to 100, got \(log.frame.height)")
            drag(0, clicks: 2)
            try await settle()
            #expect(split.layout.isCollapsed && log.frame.height == 0, "double-click hides")
            drag(0, clicks: 2)
            try await settle()
            #expect(!split.layout.isCollapsed && log.frame.height == 100, "double-click shows")

            // A short window squeezes the console to leave the device 160 pt, and gives the height back.
            drag(300)
            #expect(log.frame.height == 400, "set up 400, got \(log.frame.height)")
            resize(400)
            #expect(
                log.frame.height == 240 && top.frame.height == 160,
                "short window: console 240, got \(log.frame.height)"
            )
            resize(600)
            #expect(
                log.frame.height == 400 && split.layout.height == 400,
                "tall again: the console's height comes back"
            )
            let again = ConsoleSplitView(top: NSView(), autosaveName: "view", defaults: defaults)
            #expect(
                again.layout == L(height: 400, isCollapsed: false) && again.bar.toggleButton.state == .on,
                "restored"
            )
        }
    }
}
