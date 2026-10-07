// Downloads and preparations per catalog entry, for the sidebar rows and the
// placeholder (DeviceSession.swift's DeviceRow reads `jobs`).
//
// Download and Prepare: an IPSW either store already has, else a CDN download;
// then `firmwarekit create` (PreparationJob), then a device in the library.
// Import: hash, match, clone into State/IPSW, then the same preparation.
// The built-in device (the catalog's `bundled`): its packed base unpacked by
// `firmwarekit unpack-base` with an identity of its own, published the same way.

import FirmwareSchema
import Foundation

/// The app's instance is FirmwareJobs.shared (FirmwareJobs+App.swift); tests make their own over temporary roots.
@MainActor public final class FirmwareJobs {
    /// Posted on the main actor after `jobs` changes.
    public static let didChangeNotification = Notification.Name("FirmwareJobsDidChange")
    /// Posted on the main actor when a preparation becomes a device; `object` is its catalog entry id.
    public static let didPublishNotification = Notification.Name("FirmwareJobsDidPublish")

    public internal(set) var jobs: [String: FirmwareJob] = [:] {
        didSet { NotificationCenter.default.post(name: Self.didChangeNotification, object: self) }
    }

    private let catalog: FirmwareCatalog
    private let store: IPSWStore
    private var downloads: FirmwareDownloads!
    private var preparations: [String: PreparationJob] = [:]
    /// When each job's current phase started and how far along it was, for time remaining.
    private var starts: [String: (date: Date, fraction: Double)] = [:]
    /// The IPSWs (sha1s) each downloading job waits for: the entry's own and, for a recipe with
    /// keybag_ramdisk_from, its sibling's. One job, one bar, weighted by size; prepared when all are here.
    private var waiting: [String: [String]] = [:]
    /// Downloads with a live task, and how far each is.
    private var inFlight: [String: Double] = [:]
    private let bytes: [String: Int64]
    /// The host each download comes from once its first source failed (FirmwareDownloads' fallback).
    private var mirrors: [String: String] = [:]
    /// Each download job's last speed sample (when, bytes so far) and its measured bytes per second.
    private var speedSamples: [String: (date: Date, bytes: Double)] = [:]
    private var speeds: [String: Double] = [:]
    private let firstHosts: [String: String]
    /// The state root (Preparing/ and Devices/), the log root, and ~/Library/Caches/<bundle> (the preparer's Decrypted/).
    private let state: URL, logs: URL, caches: URL
    /// firmwarekit, if this build has it (FirmwareJobs.preparer).
    public let preparer: URL?
    /// The bundle's Resources (the built-in device's packed base).
    private let resources: URL?
    private let library: DeviceLibrary
    /// Errors with no row to show them on (an IPSW dropped on the window, a second device for an entry).
    private let presentError: (any Error) -> Void

    /// `configuration`: tests use an ephemeral session and file URLs. `sweep`: this process holds the library's
    /// lock (Bundled.requireStorage), so staging and torn downloads a previous launch left can go.
    public init(
        catalog: FirmwareCatalog = .bundled,
        store: IPSWStore = .shared,
        configuration: URLSessionConfiguration = .background(withIdentifier: FirmwareDownloads.identifier),
        state: URL = Bundled.stateDirectory,
        logs: URL = Bundled.logsDirectory,
        caches: URL = IPSWStore.cachesDirectory,
        preparer: URL? = FirmwareJobs.preparer,
        resources: URL? = Bundle.main.resourceURL,
        library: DeviceLibrary = .shared,
        sweep: Bool = (try? Bundled.requireStorage()) != nil,
        presentError: @escaping (any Error) -> Void
    ) {
        self.catalog = catalog
        self.store = store
        self.state = state
        self.logs = logs
        self.caches = caches
        self.preparer = preparer
        self.resources = resources
        self.library = library
        self.presentError = presentError
        // Staging a previous launch left behind is never a device; nor is a
        // torn download or import. Only the app holding the library's lock
        // may sweep: another copy's jobs could be live.
        if sweep {
            PreparationJob.sweep(state: state, preparer: preparer)
            store.sweep()
        }
        // Keyed by the IPSW's sha1 (a task's name); what is downloaded and weighed is the archive for a "rar" source.
        let bytes = Dictionary(
            catalog.entries.compactMap { e in e.source.sha1.map { ($0, e.source.downloadBytes ?? 0) } },
            uniquingKeysWith: { a, _ in a }
        )
        let entries = Dictionary(
            catalog.entries.compactMap { e in e.source.sha1.map { ($0, e) } },
            uniquingKeysWith: { a, _ in a }
        )
        self.bytes = bytes
        let urls = Dictionary(
            catalog.entries.compactMap { e in e.source.sha1.map { ($0, e.source.urls) } },
            uniquingKeysWith: { a, _ in a }
        )
        firstHosts = urls.compactMapValues { $0.first?.host }
        // Made at launch so a download the last launch started reports here.
        // ponytail: a task resumed at launch from a mirror shows no mirror line until the next fallback.
        // The source or mirror the file came from decides how it is checked: a "rar" one is unwrapped.
        let install: @Sendable (String, URL, URL?) throws -> URL = { sha1, file, from in
            guard var entry = entries[sha1] else { return try store.install(file, sha1: sha1, bytes: bytes[sha1]) }
            entry.source = entry.source.alternative(for: from)
            guard entry.source.isArchive else { return try store.install(file, sha1: sha1, bytes: entry.source.bytes) }
            return try store.installArchive(file, entry: entry, preparer: preparer)
        }
        downloads = FirmwareDownloads(
            store: store,
            configuration: configuration,
            expectedBytes: { bytes[$0] },
            sources: { urls[$0] ?? [] },
            install: install
        ) { [weak self] sha1, event in
            Task { @MainActor in self?.download(sha1, event) }
        }
        // ponytail: a resumed download reports under its own entry, so a sibling IPSW the last
        // launch was fetching for 4.3.x prepares its own entry; persist `waiting` if that matters.
        downloads.active { sha1s in
            Task { @MainActor [weak self] in
                guard let self else { return }
                for sha1 in sha1s {
                    inFlight[sha1] = inFlight[sha1] ?? 0
                    if let entry = entry(sha1: sha1), jobs[entry.id] == nil {
                        starts[entry.id] = nil
                        waiting[entry.id] = [sha1]
                        jobs[entry.id] = .downloading(fraction: 0)
                    }
                }
            }
        }
    }

    private func entry(sha1: String) -> FirmwareCatalog.Entry? { catalog.entries.first { $0.source.sha1 == sha1 } }

    // MARK: - Preparer

    /// Contents/MacOS/firmwarekit; a Debug build may name another with LTM_FIRMWAREKIT.
    public nonisolated static var preparer: URL? {
        #if DEBUG
            if let path = ProcessInfo.processInfo.environment["LTM_FIRMWAREKIT"] {
                return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
            }
        #endif
        return Bundle.main.executableURL.map { $0.deletingLastPathComponent().appendingPathComponent("firmwarekit") }
            .flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }

    /// Contents/MacOS/LightTouchDevice, for the preparer's one-shot boots.
    public static var helper: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/LightTouchDevice")
    }

    /// True once a download and preparation can run: the preparer is present.
    public var canDownload: Bool { preparer != nil }

    /// Why Download and Prepare is off, for the placeholder.
    public var unavailableReason: String? {
        canDownload
            ? nil
            : "This copy of Light Touch can’t prepare devices because a component is missing. Reinstall Light Touch."
    }

    // MARK: - Commands

    public func downloadAndPrepare(_ entry: FirmwareCatalog.Entry) {
        guard jobs[entry.id].map({ if case .failed = $0 { true } else { false } }) ?? true else { return }
        if let blob = Self.bundledBlob(entry, resources: resources) { return prepare(entry, ipsw: blob, bundled: true) }
        guard let sha1 = entry.source.sha1, !refuseExisting(entry) else { return }
        // The entry's IPSW and its keybag sibling's (4.3.1–4.3.5 boot 4.3's ramdisk), whichever aren't here yet.
        let sources = ([entry] + [entry.recipe?.keybagRamdiskFrom.flatMap(catalog.entry(id:))].compactMap { $0 })
            .filter { $0.source.sha1.flatMap(store.existing) == nil }
        if sources.isEmpty, let ipsw = store.existing(sha1) { return prepare(entry, ipsw: ipsw) }
        fetch(entry, sources)
    }

    /// Downloads `sources`' IPSWs as one job for `entry`, which is prepared once they're all here.
    /// A download another job already started is shared, not started twice.
    private func fetch(_ entry: FirmwareCatalog.Entry, _ sources: [FirmwareCatalog.Entry]) {
        let wanted = sources.compactMap { source in
            source.source.sha1.flatMap { sha1 in source.source.url.map { (sha1, $0) } }
        }
        guard wanted.count == sources.count, !wanted.isEmpty else { return fail(entry, FirmwareError.unsupported) }
        do {
            // The IPSWs, then the preparation, beside every job already under way.
            let size = sources.reduce(0) {
                $0 + ($1.source.bytes ?? 0) + ($1.source.isArchive ? $1.source.archiveBytes ?? 0 : 0)
            }
            try IPSWStore.checkSpace(size + entry.estimates.peakBytes + inFlightPeakBytes, at: store.downloads)
            starts[entry.id] = nil
            waiting[entry.id] = wanted.map(\.0)
            jobs[entry.id] = .downloading(fraction: downloadFraction(entry.id), files: wanted.count)
            for (sha1, url) in wanted where inFlight[sha1] == nil {
                inFlight[sha1] = 0
                try downloads.start(sha1: sha1, url: url)
            }
        } catch {
            waiting[entry.id] = nil
            fail(entry, error)
        }
    }

    /// How far a job's downloads are together, by their catalog sizes.
    private func downloadFraction(_ id: String) -> Double {
        let sha1s = waiting[id] ?? []
        let weight = { (sha1: String) in Double(max(self.bytes[sha1] ?? 1, 1)) }
        let total = sha1s.reduce(0) { $0 + weight($1) }
        let done = sha1s.reduce(0) { $0 + weight($1) * (self.inFlight[$1] ?? (self.store.existing($1) != nil ? 1 : 0)) }
        return total > 0 ? done / total : 0
    }

    /// Hashes, matches in the catalog and clones into State/IPSW, then
    /// prepares. `entry` is the row it was dropped on or imported for, if any.
    public func importIPSW(_ url: URL, for entry: FirmwareCatalog.Entry?) {
        if let entry, refuseExisting(entry) { return }
        if let entry { jobs[entry.id] = .preparing(.init(name: "Checking the IPSW")) }
        let catalog = catalog
        let store = store
        Task.detached {
            let result = Result { try store.importIPSW(url, catalog: catalog) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch result {
                case .success((let matched, let ipsw)):
                    if let entry {
                        guard jobs[entry.id] != nil else { return }  // cancelled while hashing
                        jobs[entry.id] = nil
                    }
                    jobs[matched.id] = nil
                    prepare(matched, ipsw: ipsw)
                case .failure(let error):
                    if let entry { fail(entry, error) } else { presentError(error) }
                }
            }
        }
    }

    /// App quit: every preparer gets SIGTERM (its own cancel path detaches
    /// its images); the next launch's sweep removes what's left.
    public func cancelAll() {
        for job in preparations.values { job.cancel() }
    }

    /// Peak disk use of the downloads and preparations under way.
    private var inFlightPeakBytes: Int64 {
        jobs.compactMap { id, job -> Int64? in
            switch job {
            case .downloading, .preparing: catalog.entry(id: id)?.estimates.peakBytes
            case .failed: nil
            }
        }.reduce(0, +)
    }

    /// One device per entry: an IPSW for an entry that has one (a drop, an
    /// import, a download) is refused rather than prepared again.
    private func refuseExisting(_ entry: FirmwareCatalog.Entry) -> Bool {
        guard !library.instances(firmware: entry.id).isEmpty else { return false }
        logEvent("firmware: \(entry.id) already has a device; not preparing another")
        presentError(FirmwareError.failed("\(entry.marketingName) iOS \(entry.version) already has a device."))
        return true
    }

    public func cancel(_ entry: FirmwareCatalog.Entry) {
        speedSamples[entry.id] = nil
        speeds[entry.id] = nil
        if let job = preparations[entry.id] {
            job.cancel()
        } else if let sha1s = waiting.removeValue(forKey: entry.id) {
            // A download another job still waits for goes on.
            for sha1 in sha1s where inFlight[sha1] != nil && !waiting.values.contains(where: { $0.contains(sha1) }) {
                inFlight[sha1] = nil
                downloads.cancel(sha1: sha1)
            }
        }
        jobs[entry.id] = nil
    }

    // MARK: - Steps

    /// One IPSW's event, for every job waiting on it.
    private func download(_ sha1: String, _ event: FirmwareDownloads.Event) {
        let name = entry(sha1: sha1)?.id ?? sha1
        let ids = waiting.filter { $0.value.contains(sha1) }.map(\.key).sorted()
        switch event {
        case .progress(let fraction):
            guard inFlight[sha1] != nil else { return }
            inFlight[sha1] = fraction
            for id in ids {
                guard let entry = catalog.entry(id: id), case .downloading? = jobs[id], let sha1s = waiting[id] else {
                    continue
                }
                let overall = downloadFraction(id)
                // The bar spans the download and the preparation: the time left is both.
                let left = remaining(entry, overall).map { $0 + Double(entry.estimates.seconds) }
                jobs[id] = .downloading(
                    fraction: overall,
                    remaining: left,
                    files: sha1s.count,
                    mirror: sha1s.lazy.compactMap { self.mirrors[$0] ?? self.firstHosts[$0] }.first.flatMap(
                        FirmwareJob.thirdParty
                    ),
                    speed: speed(id, bytes: overall * Double(sha1s.reduce(0) { $0 + (self.bytes[$1] ?? 0) }))
                )
            }
        case .mirror(let url): mirrors[sha1] = url.host
        case .resumed: break
        case .finished:
            inFlight[sha1] = nil
            mirrors[sha1] = nil
            logEvent("firmware: downloaded \(name)")
            // A job with nothing left to fetch prepares; one still fetching the other IPSW waits.
            for id in ids {
                guard let entry = catalog.entry(id: id), let sha1s = waiting[id],
                    sha1s.allSatisfy({ inFlight[$0] == nil })
                else { continue }
                waiting[id] = nil
                guard let own = entry.source.sha1, let ipsw = store.existing(own) else {
                    fail(entry, FirmwareError.failed("The download of iOS \(entry.version) is missing."))
                    continue
                }
                prepare(entry, ipsw: ipsw, afterDownload: true)
            }
            // Nobody waits (the other IPSW of a job that failed): it stays downloaded.
            if ids.isEmpty { NotificationCenter.default.post(name: Self.didChangeNotification, object: self) }
        case .failed(let error):
            inFlight[sha1] = nil
            mirrors[sha1] = nil
            for id in ids {
                waiting[id] = nil
                if let entry = catalog.entry(id: id) { fail(entry, error) }
            }
        case .cancelled:
            mirrors[sha1] = nil
            logEvent("firmware: download of \(name) cancelled and discarded")
        }
    }

    /// Bytes per second over the last few seconds of a job's download; nil until measured.
    private func speed(_ id: String, bytes: Double) -> Double? {
        let now = Date()
        guard let sample = speedSamples[id] else {
            speedSamples[id] = (now, bytes)
            return nil
        }
        let elapsed = now.timeIntervalSince(sample.date)
        if elapsed >= 3 {
            let rate = max(0, bytes - sample.bytes) / elapsed
            // Smoothed, so one slow interval doesn't swing it.
            speeds[id] = speeds[id].map { $0 * 0.6 + rate * 0.4 } ?? rate
            speedSamples[id] = (now, bytes)
        }
        return speeds[id]
    }

    /// The entry's packed base in this bundle (a development build has none).
    public static func bundledBlob(_ entry: FirmwareCatalog.Entry, resources: URL? = Bundle.main.resourceURL) -> URL? {
        guard let resource = entry.bundled, let blob = resources?.appendingPathComponent(resource),
            FileManager.default.fileExists(atPath: blob.path)
        else { return nil }
        return blob
    }

    /// A fresh install (`sidebarSaved` false: no launch has saved a sidebar yet; and no device in the library): the
    /// built-in device is unpacked and returned, for the launch to select. A Mac that already has a library gets
    /// nothing new; its Prepare is the user's (the row offers it once added with +, and after a Delete).
    public func prepareBundledIfFresh(sidebarSaved: Bool) -> FirmwareCatalog.Entry? {
        guard !sidebarSaved, DeviceInstance.all(state: state).isEmpty,
            let entry = catalog.bundledEntry, let blob = Self.bundledBlob(entry, resources: resources)
        else { return nil }
        prepare(entry, ipsw: blob, bundled: true)
        return entry
    }

    /// `bundled`: `ipsw` is the entry's packed base, unpacked rather than prepared. `afterDownload`: the job's
    /// download filled the first half of its bar.
    private func prepare(_ entry: FirmwareCatalog.Entry, ipsw: URL, bundled: Bool = false, afterDownload: Bool = false)
    {
        speedSamples[entry.id] = nil
        speeds[entry.id] = nil
        guard preparations[entry.id] == nil else { return }
        if refuseExisting(entry) {
            jobs[entry.id] = nil
            return
        }
        guard let preparer else { return fail(entry, FirmwareError.failed(unavailableReason ?? "")) }
        let others = jobs.filter { $0.key != entry.id }.compactMap { id, job -> Int64? in
            if case .preparing = job { return catalog.entry(id: id)?.estimates.peakBytes } else { return nil }
        }.reduce(0, +)
        do { try IPSWStore.checkSpace(entry.estimates.peakBytes + others, at: state) } catch {
            return fail(entry, error)
        }
        var sibling: (entry: FirmwareCatalog.Entry, ipsw: URL)?
        if !bundled, let from = entry.recipe?.keybagRamdiskFrom {
            guard let sib = catalog.entry(id: from), let sha1 = sib.source.sha1 else {
                return fail(entry, FirmwareError.failed("catalog names no \(from)"))
            }
            // An imported IPSW whose sibling isn't here yet: that download first, as this entry's job.
            guard let sibIPSW = store.existing(sha1) else { return fetch(entry, [sib]) }
            sibling = (sib, sibIPSW)
        }
        let request = PreparationJob.Request(
            entry: entry,
            ipsw: ipsw,
            sibling: sibling,
            state: state,
            preparer: preparer,
            helper: Self.helper,
            cache: caches.appendingPathComponent("Decrypted", isDirectory: true),
            log: logs.appendingPathComponent("Preparing/\(entry.id).log"),
            blob: bundled ? ipsw : nil
        )
        let job = PreparationJob(request) { event in
            Task { @MainActor [weak self] in self?.preparation(entry, event) }
        }
        preparations[entry.id] = job
        starts[entry.id] = (Date(), 0)
        jobs[entry.id] = .preparing(.init(name: "Starting", startsAt: afterDownload ? 0.5 : 0))
        logEvent("firmware: \(bundled ? "unpacking the built-in" : "preparing") \(entry.id) as \(job.id.uuidString)")
        job.start()
    }

    /// Seconds left from this phase's start (the first report of a resumed download) to `fraction` now.
    private func remaining(_ entry: FirmwareCatalog.Entry, _ fraction: Double) -> TimeInterval? {
        guard let start = starts[entry.id] else {
            starts[entry.id] = (Date(), fraction)
            return nil
        }
        return estimatedRemaining(elapsed: Date().timeIntervalSince(start.date), from: start.fraction, to: fraction)
    }

    private func preparation(_ entry: FirmwareCatalog.Entry, _ event: PreparationJob.Event) {
        func update(_ change: (inout Preparation) -> Void) {
            guard preparations[entry.id] != nil, case .preparing(var p)? = jobs[entry.id] else { return }
            change(&p)
            p.remaining = p.overall.flatMap { remaining(entry, $0) }
            jobs[entry.id] = .preparing(p)
        }
        switch event {
        case .begin(let seconds): update { $0.seconds = seconds }
        case .step(let index, let count, let name):
            update {
                $0.step = index
                $0.steps = count
                $0.name = name
                $0.fraction = 0
                $0.detail = nil
            }
        case .progress(let fraction, let detail):
            update {
                $0.fraction = fraction
                $0.detail = detail ?? $0.detail
            }
        case .warning(let message): logEvent("firmware: \(entry.id): \(message)")
        case .published(let instance):
            preparations[entry.id] = nil
            jobs[entry.id] = nil
            logEvent("firmware: \(entry.id) is device \(instance.id.uuidString)")
            library.reload()
            NotificationCenter.default.post(name: Self.didPublishNotification, object: entry.id)
        case .failed(let message):
            preparations[entry.id] = nil
            fail(entry, FirmwareError.failed(message))
        case .cancelled:
            preparations[entry.id] = nil
            logEvent("firmware: preparation of \(entry.id) cancelled")
        }
    }

    private func fail(_ entry: FirmwareCatalog.Entry, _ error: any Error) {
        logEvent("firmware: \(entry.id): \(error.localizedDescription)")
        jobs[entry.id] = .failed(error.localizedDescription)
    }
}
