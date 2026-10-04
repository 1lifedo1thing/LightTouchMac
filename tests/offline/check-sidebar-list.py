#!/usr/bin/env python3
"""The sidebar's list (SidebarList): which entries it shows, in what order, what each row says, and what persists.

Compiles SidebarList.swift with the real FirmwareCatalog and DeviceRow against the shipped catalog, on a throwaway
UserDefaults suite. Checks:
- titles: always two lines, the model identifier ("iPod2,1") over the version with its badge ("iOS 4.1 Beta 1"),
  whatever else is listed; a custom name -> the name over "iPod2,1, iOS 4.1";
- rename: saved and read back by a fresh load; an empty name or the default title clears it; removing forgets it;
- migration: no saved list -> the entries the user owns (prepared / downloaded / in flight), else first_run;
  a saved list (even empty) is kept as saved, entries the catalog dropped are skipped;
- order: whatever order entries are added in, rows list per board in version order, betas before their release;
- removal: a prepared device's row says Delete Device… and asks through delete; others say Remove Device; nothing
  running or in flight can leave.
"""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import host_runtime
from firmwarekit_leaf import schema_sources
import subprocess, tempfile

app = Path(__file__).resolve().parents[2] / 'LightTouchMac'

check = r'''
import Foundation
@main struct Check {
    static func main() throws {
        let catalog = try FirmwareCatalog.load(from: URL(fileURLWithPath: CommandLine.arguments[1]))
        func entry(_ id: String) -> FirmwareCatalog.Entry { catalog.entry(id: id)! }
        let suite = "ltm-check-sidebar-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // Migration: a fresh install gets first_run, saved at once.
        var list = SidebarList.load(defaults, catalog: catalog) { _ in false }
        precondition(list.ids == ["k48ap-7B500"], "fresh install: \(list.ids)")
        precondition(defaults.stringArray(forKey: SidebarList.entriesKey) == ["k48ap-7B500"], "fresh install not saved")
        // An updating user keeps what they own, in catalog order; first_run isn't forced in.
        defaults.removeObject(forKey: SidebarList.entriesKey)
        let owned: Set = ["n72ap-7E18", "n72ap-8B117", "k48ap-8C148"]
        list = SidebarList.load(defaults, catalog: catalog) { owned.contains($0.id) }
        precondition(list.entries(in: catalog).map(\.id) == ["k48ap-8C148", "n72ap-7E18", "n72ap-8B117"], "migration: \(list.ids)")
        // Once saved, the list rules: owned entries the user removed don't return on the next launch.
        list.remove("n72ap-7E18")
        list.save(defaults)
        list = SidebarList.load(defaults, catalog: catalog) { owned.contains($0.id) }
        precondition(Set(list.ids) == ["k48ap-8C148", "n72ap-8B117"], "reload after remove: \(list.ids)")
        // An empty list stays empty (the sidebar shows Add Device…); ids the catalog lost are dropped.
        SidebarList(ids: []).save(defaults)
        precondition(SidebarList.load(defaults, catalog: catalog) { _ in true }.ids.isEmpty, "empty list refilled")
        SidebarList(ids: ["n72ap-gone", "n72ap-8C148"], names: ["n72ap-gone": "Old"]).save(defaults)
        list = SidebarList.load(defaults, catalog: catalog) { _ in false }
        precondition(list.ids == ["n72ap-8C148"] && list.names.isEmpty, "stale ids: \(list)")

        // Order: added backwards and interleaved, listed per board in version order, betas before the release.
        list = SidebarList()
        list.add(["n72ap-8C148", "n72ap-8B117", "k48ap-7B500", "n72ap-8B5080c", "n72ap-5F138", "k48ap-7B367"])
        precondition(list.add(["n72ap-8B117"]) == false, "added twice")
        let order = list.entries(in: catalog).map(\.id)
        precondition(order == ["k48ap-7B367", "k48ap-7B500", "n72ap-5F138", "n72ap-8B5080c", "n72ap-8B117", "n72ap-8C148"], "order: \(order)")

        // Titles: the model identifier over the version and its badge, the same whatever else is listed.
        list = SidebarList(ids: ["n72ap-8B117", "n72ap-8B5080c"])
        precondition(list.label(for: entry("n72ap-8B117")) == .init(title: "iPod2,1", subtitle: "iOS 4.1"), "\(list.label(for: entry("n72ap-8B117")))")
        precondition(list.label(for: entry("n72ap-8B5080c")) == .init(title: "iPod2,1", subtitle: "iOS 4.1 Beta 1"), "beta")
        list.add(["k48ap-7B500", "n45ap-4B1"])
        precondition(list.label(for: entry("n72ap-8B117")) == .init(title: "iPod2,1", subtitle: "iOS 4.1"), "mixed list changed the label")
        precondition(list.label(for: entry("k48ap-7B500")) == .init(title: "iPad1,1", subtitle: "iOS 3.2.2"), "iPad")
        precondition(list.label(for: entry("n45ap-4B1")) == .init(title: "iPod1,1", subtitle: "iOS 1.1.5"), "1G")
        precondition(list.label(for: entry("k48ap-8C134")).subtitle.hasPrefix("iOS 4.2") && list.label(for: entry("k48ap-8C134")).subtitle.hasSuffix(" GM 1"), "GM badge")
        list.remove("n45ap-4B1")

        // Rename: the name over "<identifier>, iOS x.y <badge>".
        list.rename("n72ap-8B117", to: "  Test Rig ", defaultTitle: "iPod2,1")
        precondition(list.label(for: entry("n72ap-8B117")) == .init(title: "Test Rig", subtitle: "iPod2,1, iOS 4.1"), "renamed")
        list.rename("n72ap-8B5080c", to: "Beta Rig", defaultTitle: "iPod2,1")
        precondition(list.label(for: entry("n72ap-8B5080c")) == .init(title: "Beta Rig", subtitle: "iPod2,1, iOS 4.1 Beta 1"), "renamed beta")
        list.rename("n72ap-8B5080c", to: "", defaultTitle: "iPod2,1")
        list.remove("k48ap-7B500")
        list.save(defaults)
        var reloaded = SidebarList.load(defaults, catalog: catalog) { _ in false }
        precondition(reloaded.names == ["n72ap-8B117": "Test Rig"] && reloaded == list, "names not persisted: \(reloaded)")
        reloaded.rename("n72ap-8B117", to: "iPod2,1", defaultTitle: "iPod2,1")
        precondition(reloaded.names.isEmpty, "the default title became a custom name")
        reloaded.rename("n72ap-8B5080c", to: "Beta", defaultTitle: "iPod2,1")
        reloaded.rename("n72ap-8B5080c", to: "   ", defaultTitle: "iPod2,1")
        precondition(reloaded.names.isEmpty, "an empty name kept")
        reloaded.rename("n72ap-8B117", to: "X", defaultTitle: "iPod2,1")
        reloaded.remove("n72ap-8B117")
        reloaded.add(["n72ap-8B117"])
        precondition(reloaded.names.isEmpty, "a removed row kept its name")

        // Removal: prepared -> Delete Device… (asks, through delete); nothing on disk -> Remove Device.
        let e = entry("n72ap-8B117")
        func row(_ instance: UUID?, session: SessionPhase? = nil, job: FirmwareJob? = nil, downloaded: Bool = false) -> DeviceRow {
            DeviceRow(entry: e, instanceID: instance, session: session, job: job, downloaded: downloaded)
        }
        let prepared = row(UUID())
        precondition(prepared.removeTitle == "Delete Device…" && prepared.canRemoveFromSidebar, "prepared")
        precondition(row(nil).removeTitle == "Remove Device" && row(nil).canRemoveFromSidebar && row(nil, downloaded: true).canRemoveFromSidebar, "not prepared")
        precondition(!row(UUID(), session: .running).canRemoveFromSidebar, "a running device left the sidebar")
        precondition(!row(nil, job: .downloading(fraction: 0.3)).canRemoveFromSidebar, "a download in flight left the sidebar")
        precondition(!row(nil, job: .preparing(Preparation(name: "x"))).canRemoveFromSidebar, "a preparation in flight left the sidebar")
        // Deleting: the row says so, can't start, be deleted again or open; it outranks a ready state.
        let deleting = DeviceRow(entry: e, instanceID: UUID(), session: nil, job: nil, deleting: true)
        precondition(deleting.state == .deleting && deleting.accessory == .stopping && deleting.stateDescription == "Deleting", "\(deleting.state)")
        precondition(DeviceAction.allCases.allSatisfy { !deleting.allows($0, canDownload: true) } && deleting.primaryAction == nil
                     && !deleting.canRemoveFromSidebar, "a deleting row offers an action")
        print("PASS: sidebar list: migration, catalog order, titles and subtitles, rename persistence, removal")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='ltm-sidebar-list-') as tmp:
    tmp = Path(tmp)
    (tmp / 'main.swift').write_text(check)
    subprocess.run(['xcrun', 'swiftc', *host_runtime.swift_flags(Path(__file__).resolve().parents[2]), *schema_sources(), '-parse-as-library', '-swift-version', '5', '-module-cache-path', str(tmp / 'modules'),
                    str(app / 'Library/FirmwareCatalog.swift'), str(app / 'Device/DeviceProfile.swift'),
                    str(app / 'Device/DeviceRow.swift'), str(app / 'Library/SidebarList.swift'),
                    str(tmp / 'main.swift'), '-o', str(tmp / 'check')], check=True)
    subprocess.run([str(tmp / 'check'), str(app / 'Resources/firmware-catalog.json')], check=True, timeout=60)
