# Checks that still compile a string slice of a production file

A slice is `source[source.index('marker'):source.index('other marker')]` over a production file, wrapped in a
fixture that stands in for the rest of it; it breaks whenever the markers move. The hubs' slices (EmulatorController,
AppsInspectorViewController, MainWindowController, DisplayView, AppDelegate) are retired: their logic is in
LightTouchCore types tested by LightTouchCoreTests (Swift Testing, `Unit.xctestplan`), and the checks of real AppKit
views that remain in `tests/offline` compile the views whole (check-model's fixture, synthetic events, no window).

What still slices:

| Check | Slices | Why |
|---|---|---|
| offline/check-reap-reason | the `DeviceLinkError`/`DeviceTermination` enums out of `Packages/DeviceRuntime/Sources/DeviceRuntime/DeviceLink.swift` | Its race half swaps `DeviceLink` itself for a stand-in, which an import of DeviceRuntime can't do. The classification, labels and drain are `DeviceProcessTests`. |

Not production slices, listed so nobody hunts for them: `offline/check-model-startup` and the other whole-DisplayView
checks take `check-model.py`'s fixture; `offline/check-window-restoration` asserts the order of three calls in
`App/main.swift`; `sessions/matrix.py` and `release/test-dependency-sources.py` use `index()` on their own data.
