import Cocoa
import LightTouchCore

// The window's zoom: the toolbar's segmented control, the View menu's zoom items and ⌘+/−, one ZoomMode applied to
// the device view and remembered across launches: the single source of truth for the toggle, menu, and view.

extension MainWindowController {
    @objc private func zoomSegmentClicked(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: zoomOut(sender)
        case 1: zoomToFit(sender)
        default: zoomIn(sender)
        }
    }

    func apply(_ mode: ZoomMode) {
        guard let deviceVC else { return }
        let mode = mode == .physical && deviceVC.screen.physicalScale == nil ? ZoomMode.fit : mode
        zoom = mode
        deviceVC.setZoom(mode)
        syncZoomControls()
        Self.saveZoom(mode)
    }

    private static func saveZoom(_ mode: ZoomMode) {
        UserDefaults.standard.set(mode.defaultsValue, forKey: ZoomMode.defaultsKey)
    }
    static func savedZoom() -> ZoomMode {
        ZoomMode(defaultsValue: UserDefaults.standard.string(forKey: ZoomMode.defaultsKey))
    }

    /// Gray out a direction there is no room left in.
    func syncZoomControls() {
        let step = zoom.percent.map { $0 / 100 }
        zoomControl.setEnabled(step != ZoomMode.steps.first, forSegment: 0)
        zoomControl.setEnabled(step != ZoomMode.steps.last, forSegment: 2)
    }

    /// One notch along the ladder, from the pinch gesture and from ⌘+ / ⌘−.
    /// Stepping out of Fit starts from whatever size Fit happens to be showing,
    /// so the first press nudges the device rather than jumping it.
    func stepZoom(_ direction: Int) {
        guard let deviceVC else { return }
        apply(ZoomMode.step(from: deviceVC.screen.pixelMultiple, direction: direction))
    }

    @objc func zoomIn(_ sender: Any?) { stepZoom(1) }
    @objc func zoomOut(_ sender: Any?) { stepZoom(-1) }
    @objc func zoomPhysicalSize(_ sender: Any?) { apply(.physical) }
    @objc func zoomToFit(_ sender: Any?) { apply(.fit) }
    @objc func zoomPixelAccurate(_ sender: Any?) { apply(.pixels(1)) }

    func configureZoomControl() {
        // Out, zoom to fit, in. Momentary, because all are commands rather than states
        // to sit in — which state you are in is the menu's job, where the
        // checkmarks live.
        zoomControl.segmentCount = 3
        zoomControl.trackingMode = .momentary
        zoomControl.segmentStyle = .separated
        let symbols = [
            ("minus.magnifyingglass", "Zoom Out", "⌘−"),
            ("arrow.up.left.and.down.right.magnifyingglass", "Zoom to Fit", "⌘0"),
            ("plus.magnifyingglass", "Zoom In", "⌘+"),
        ]
        for (index, (symbol, label, key)) in symbols.enumerated() {
            zoomControl.setImage(
                NSImage(systemSymbolName: symbol, accessibilityDescription: label),
                forSegment: index
            )
            zoomControl.setToolTip("\(label) (\(key))", forSegment: index)
        }
        zoomControl.target = self
        zoomControl.action = #selector(zoomSegmentClicked(_:))
        zoomControl.sizeToFit()
    }

    func makeZoomToolbarItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .zoom)
        item.label = "Zoom"
        item.paletteLabel = "Zoom"
        item.toolTip = "Change the device’s size"
        item.view = zoomControl
        return item
    }

    /// Enablement and checkmarks for the View menu's zoom items.
    func validateZoomItem(_ menuItem: NSMenuItem, screen: DisplayView) -> Bool {
        switch menuItem.action {
        case #selector(zoomIn(_:)):
            guard let largest = ZoomMode.steps.last else { return false }
            return zoom.percent.map { $0 / 100 } ?? 0 < largest
        case #selector(zoomOut(_:)):
            return zoom != .pixels(ZoomMode.steps[0])
        case #selector(zoomPhysicalSize(_:)):
            menuItem.state = (zoom == .physical) ? .on : .off
            return screen.physicalScale != nil
        case #selector(zoomToFit(_:)):
            menuItem.state = (zoom == .fit) ? .on : .off
            return true
        case #selector(zoomPixelAccurate(_:)):
            menuItem.state = (zoom == .pixels(1)) ? .on : .off
            return true
        default:
            return true
        }
    }
}
