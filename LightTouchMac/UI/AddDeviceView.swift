// The Add Device sheet: the firmware catalog split by device. Devices on the left, with their artwork and how many of
// their versions are picked; the chosen device's versions on the right, in version order, each with its support
// status and whether its IPSW is here (else its download size), and below them what the picked versions are. Versions
// already in the sidebar are checked and can't be picked again. Only stable builds show until Show experimental is on
// (remembered). Picks survive switching devices; Add adds them all.
// A sheet, not a window: it belongs to the one main window and is done before the user goes on (HIG, Sheets).

import FirmwareSchema
import HostRuntime
import LightTouchCore
import SwiftUI

struct AddDeviceView: View {
    struct Group: Identifiable {
        let id: String
        let name: String
        let icon: NSImage
        let entries: [FirmwareCatalog.Entry]
    }

    let groups: [Group]
    let added: Set<String>
    let downloaded: Set<String>
    let onAdd: ([String]) -> Void
    let onCancel: () -> Void
    @State private var selection: Set<String>
    @State private var device: String?
    @AppStorage("addDeviceShowsExperimental") private var showsExperimental = false

    init(
        catalog: FirmwareCatalog,
        added: Set<String>,
        downloaded: Set<String>,
        selection: Set<String> = [],
        device: String? = nil,
        onAdd: @escaping ([String]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        var boards: [String] = []
        for entry in catalog.entries where !boards.contains(entry.board) { boards.append(entry.board) }
        groups = boards.map { board in
            let entries = catalog.entries.filter { $0.board == board }
            let profile = entries[0].profile
            return Group(
                id: board,
                name: profile?.marketingName ?? entries[0].productType,
                icon: profile?.icon
                    ?? Board.icon(modelCode: entries[0].productType, fallbackSymbol: "questionmark.square.dashed"),
                entries: entries
            )
        }
        self.added = added
        self.downloaded = downloaded
        self.onAdd = onAdd
        self.onCancel = onCancel
        _selection = State(initialValue: selection)
        _device = State(initialValue: device ?? catalog.entries.first { selection.contains($0.id) }?.board)
    }

    /// Stable: supported (`available`), or a release supported from the user's own IPSW (not a beta or GM).
    static func isStable(_ entry: FirmwareCatalog.Entry) -> Bool {
        entry.status == .available || (entry.status == .userIPSW && entry.prerelease == nil)
    }

    /// `groups` with only their stable builds unless `experimental`; a device left with none goes.
    static func shown(_ groups: [Group], experimental: Bool) -> [Group] {
        experimental
            ? groups
            : groups.compactMap { group in
                let entries = group.entries.filter(isStable)
                return entries.isEmpty ? nil : Group(id: group.id, name: group.name, icon: group.icon, entries: entries)
            }
    }

    /// What Add adds: the selected entries still shown and not already added, in catalog order, whichever device
    /// they're under.
    static func picked(_ groups: [Group], selection: Set<String>, added: Set<String>) -> [String] {
        groups.flatMap(\.entries).map(\.id).filter { selection.contains($0) && !added.contains($0) }
    }

    private var shownGroups: [Group] { Self.shown(groups, experimental: showsExperimental) }
    private var picked: [String] { Self.picked(shownGroups, selection: selection, added: added) }
    /// The device on the right: the chosen one while it's shown, else the first.
    private var shownGroup: Group? { shownGroups.first { $0.id == device } ?? shownGroups.first }

    var body: some View {
        VStack(spacing: 0) {
            // A fixed sidebar, as System Settings has: its names fit, and unlike NavigationSplitView's it can't be
            // collapsed in a sheet that has no toolbar to bring it back.
            HStack(spacing: 0) {
                List(selection: Binding(get: { shownGroup?.id }, set: { id in id.map { device = $0 } })) {
                    ForEach(shownGroups) { group in
                        Label {
                            Text(group.name)
                        } icon: {
                            Image(nsImage: group.icon).resizable().scaledToFit()
                        }
                        .badge(group.entries.count { picked.contains($0.id) })
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 270)
                Divider()
                if let group = shownGroup { versions(group) } else { Spacer() }
            }
            Divider()
            HStack {
                Toggle("Show experimental", isOn: $showsExperimental)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Add") { onAdd(picked) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(picked.isEmpty)
            }
            .padding(16)
        }
        .frame(minWidth: 660, idealWidth: 780, minHeight: 400, idealHeight: 540)
    }

    /// The sheet's window: resizable down to the view's minimum, at its last size (autosaved), else the ideal one.
    func makeSheet() -> NSWindow {
        let hosting = NSHostingController(rootView: self)
        hosting.sizingOptions = [.minSize]
        let sheet = NSWindow(contentViewController: hosting)
        sheet.styleMask = [.titled, .resizable]
        sheet.setContentSize(NSSize(width: 780, height: 540))
        sheet.setFrameAutosaveName("AddDeviceSheet")
        return sheet
    }

    private func versions(_ group: Group) -> some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section {
                    ForEach(group.entries) { entry in
                        AddDeviceRow(
                            entry: entry,
                            added: added.contains(entry.id),
                            downloaded: downloaded.contains(entry.id)
                        )
                        .selectionDisabled(added.contains(entry.id))
                    }
                } header: {
                    Text(group.name)
                }
            }
            .contextMenu(
                forSelectionType: String.self,
                menu: { _ in },
                // Double-click or Return in the list adds what's picked, as Add does.
                primaryAction: { _ in
                    if !picked.isEmpty { onAdd(picked) }
                }
            )
            Divider()
            AddDeviceSummary(
                entries: shownGroups.flatMap(\.entries).filter { picked.contains($0.id) },
                downloaded: downloaded
            )
        }
    }
}

/// One version: checked when already added, its badge, build and status, and its IPSW (here, shipped, or its size).
struct AddDeviceRow: View {
    let entry: FirmwareCatalog.Entry
    let added: Bool
    let downloaded: Bool

    private var status: String? { Self.statusText(entry.status) }

    /// Nothing for a supported build; only what sets a build apart.
    static func statusText(_ status: FirmwareCatalog.Entry.Status) -> String? {
        switch status {
        case .available: nil
        case .experimental: "Experimental"
        case .untested: "Untested"
        case .comingSoon: "Coming Soon"
        case .userIPSW: "Requires an IPSW"
        }
    }

    /// The bytes a download fetches: a developer beta's RAR archive, else the IPSW.
    static func downloadBytes(_ entry: FirmwareCatalog.Entry) -> Int64 {
        entry.source.archiveBytes ?? entry.source.bytes ?? 0
    }

    /// Where the IPSW stands: shipped prepared with the app, here, or what it takes to download.
    static func ipsw(_ entry: FirmwareCatalog.Entry, downloaded: Bool) -> String {
        if entry.bundled != nil { return "Included" }
        if downloaded { return "Downloaded" }
        return downloadBytes(entry).formatted(.byteCount(style: .file))
    }

    var body: some View {
        HStack(spacing: 6) {
            // Already in the sidebar: checked, as in a menu, and dimmed.
            Image(systemName: "checkmark")
                .foregroundStyle(.tint)
                .opacity(added ? 1 : 0)
                .frame(width: 14)
            Text("iOS \(entry.version)")
                .foregroundStyle(added ? .secondary : .primary)
            if let badge = entry.prereleaseBadge {
                Text(badge)
                    .font(.caption)
                    .padding(.horizontal, 5)
                    .background(.quaternary, in: Capsule())
            }
            Text(entry.build)
                .foregroundStyle(.secondary)
            Spacer()
            if let status {
                Text(status)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            Text(Self.ipsw(entry, downloaded: downloaded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 76, alignment: .trailing)
            // The sidebar's convention: a build that isn't here yet shows the download glyph.
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.tertiary)
                .opacity(downloaded || entry.bundled != nil ? 0 : 1)
                .frame(width: 16)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "iOS \(entry.version)\(entry.prereleaseBadge.map { " \($0)" } ?? ""), build \(entry.build)"
        )
        .accessibilityValue(
            [status, Self.ipsw(entry, downloaded: downloaded), added ? "In the sidebar" : nil]
                .compactMap { $0 }.joined(separator: ", ")
        )
    }
}

/// Below the versions: the one picked version in full (released, download, prepared size, its note), or how many are
/// picked and what they download.
struct AddDeviceSummary: View {
    let entries: [FirmwareCatalog.Entry]
    let downloaded: Set<String>

    /// What Add will download: the picked IPSWs that aren't here and don't ship with the app.
    static func downloadBytes(_ entries: [FirmwareCatalog.Entry], downloaded: Set<String>) -> Int64 {
        entries.filter { $0.bundled == nil && !downloaded.contains($0.id) }.map(AddDeviceRow.downloadBytes).reduce(0, +)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if entries.count == 1, let entry = entries.first {
                Text(
                    "\(entry.marketingName), iOS \(entry.version)\(entry.prereleaseBadge.map { " \($0)" } ?? "")"
                        + " (\(entry.build))"
                )
                .font(.headline)
                Text(facts(entry))
                    .foregroundStyle(.secondary)
                if let note = entry.statusNote {
                    Text(note)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } else if !entries.isEmpty {
                Text("\(entries.count) versions")
                    .font(.headline)
                Text(download)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .padding(12)
        .accessibilityElement(children: .combine)
    }

    private var download: String {
        let bytes = Self.downloadBytes(entries, downloaded: downloaded)
        return bytes == 0 ? "Nothing to download" : "\(bytes.formatted(.byteCount(style: .file))) to download"
    }

    private func facts(_ entry: FirmwareCatalog.Entry) -> String {
        var facts: [String] = []
        if let released = entry.released.flatMap({ try? Date($0, strategy: .iso8601.year().month().day()) }) {
            facts.append("Released \(released.formatted(date: .long, time: .omitted))")
        }
        facts.append(
            entry.bundled != nil ? "Included with Light Touch" : downloaded.contains(entry.id) ? "Downloaded" : download
        )
        facts.append("\(entry.estimates.preparedBytes.formatted(.byteCount(style: .file))) once prepared")
        return facts.joined(separator: " · ")
    }
}
