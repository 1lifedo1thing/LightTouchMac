#!/usr/bin/env python3
"""The Apps inspector's Store and transfer rows at narrow and wide widths: UI/AppRowCells.swift and
UI/InlineActionButton.swift compiled whole, against stand-ins for the LightTouchCore types they draw (CatalogApp,
InstallJob, AppInstaller.isPaused). Icons and labels align, the title stays one line, the action keeps its width
whatever its text, and a transfer shows determinate or indeterminate progress beside Cancel. What each row says
(and which row a Store result is) is AppsInspectorRowsTests'."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
fixture = r'''import Cocoa
struct CatalogApp {
 var name: String; var bundleID: String? = "test"; var version: String? = "1.0"
 var subtitle = "Example Developer · 5 MB"; var incompatibility: String? = nil
}
@MainActor final class InstallJob {
 let deviceID = UUID()
 var failed = false, isCancellable = true, status = "Downloading…"
 var retry: (() -> Void)?
 func cancel() {}
}
@MainActor enum AppInstaller { static func isPaused(_ id: UUID) -> Bool { false } }
@main struct Check {
 @MainActor static func main() {
  _ = NSApplication.shared
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 56), styleMask: [.titled], backing: .buffered, defer: false)
  enum Row { case result(String), progress(Double?) }
  for width in [240.0, 320.0, 500.0] {
   for name in ["Facebook", "Doodle Jump — BE WARNED: Insanely Addictive!"] {
    for row in [Row.result("Install"), .result("Open"), .progress(0.5), .progress(nil)] {
     let cell: NSTableCellView
     switch row {
     case .result(let button): cell = AppRowCells.catalogCell(CatalogApp(name: name), icon: nil, button: button, enabled: true, row: 0, target: nil, action: nil)
     case .progress(let fraction): cell = AppRowCells.progressCell(icon: nil, title: name, subtitle: "Downloading… 50%", fraction: fraction, job: InstallJob()) {}
     }
     window.contentView = cell; window.setContentSize(NSSize(width: width, height: 56)); window.orderFront(nil)
     cell.layoutSubtreeIfNeeded()
     let title = cell.textField!, image = cell.imageView!
     let subtitle = cell.subviews.compactMap { $0 as? NSTextField }.first { $0 !== title }!
     precondition(title.maximumNumberOfLines == 1)
     precondition(abs(title.frame.minX - subtitle.frame.minX) < 0.5)
     precondition(abs(image.frame.midY - 28) < 0.5 && abs(image.frame.width - 32) < 0.5)
     let button = cell.subviews.compactMap { $0 as? NSButton }.first!
     let buttonFrame = button.alignmentRect(forFrame: button.frame)
     if case .result = row { precondition(abs(buttonFrame.width - 60) < 0.5, "Action width changed with text") }
     else { precondition(abs(buttonFrame.width - 54) < 0.5, "Action width changed with text") }
     precondition(title.frame.maxX < buttonFrame.minX && title.frame.minX > image.frame.maxX)
     if case .progress(let fraction) = row {
      let progress = cell.subviews.compactMap { $0 as? NSProgressIndicator }.first!
      precondition(!progress.isHidden && !button.isHidden && progress.frame.width == 16, "Progress must remain visible alongside Cancel")
      precondition(progress.isIndeterminate == (fraction == nil))
     }
    }
   }
  }
  print("PASS: Store/transfer rows align icons and labels, preserve compact actions and show determinate/indeterminate progress with Cancel")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-row-layout-') as directory:
    work = Path(directory)
    (work / 'check.swift').write_text(fixture)
    subprocess.run(['swiftc', '-parse-as-library', '-default-isolation', 'MainActor', str(root / 'LightTouchMac/UI/InlineActionButton.swift'),
                    str(root / 'LightTouchMac/UI/AppRowCells.swift'), str(work / 'check.swift'), '-o', str(work / 'check')], check=True)
    subprocess.run([str(work / 'check')], check=True, timeout=20)
