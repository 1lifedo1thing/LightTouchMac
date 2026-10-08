// Tweaks (Tweaks.swift) for one device: its saved TweakSettings, and on a running device the foreground watch's
// apply (DeviceTweaks.apply), which brings the guest to them whenever they change, and once at every start.

import Foundation
import HostRuntime
import HostServiceWire
import Observation

@Observable public final class DeviceTweaks {
    @ObservationIgnored private let settingsFile: DeviceSettingsFile
    /// The device's firmware version ("4.2.1").
    public let version: String
    /// The board runs Light Touch's guest tools (the agent): no iPhone OS 1.x.
    public let guestTools: Bool
    /// The base pins its own clock (a beta kept inside its release window): Time Machine stays off.
    public let clockPinned: Bool

    public init(settings: DeviceSettingsFile, version: String, guestTools: Bool, clockPinned: Bool) {
        settingsFile = settings
        self.version = version
        self.guestTools = guestTools
        self.clockPinned = clockPinned
    }

    public var settings: TweakSettings { settingsFile.value.tweaks ?? TweakSettings() }

    public func change(_ change: (inout TweakSettings) -> Void) {
        settingsFile.change { s in
            var t = s.tweaks ?? TweakSettings()
            change(&t)
            s.tweaks = t
        }
    }

    public func isAvailable(_ tweak: Tweak) -> Bool {
        tweak.isAvailable(version: version, guestTools: guestTools, clockPinned: clockPinned)
    }

    /// The next start's clock (Time Machine), as PreparedDeviceBoot takes it.
    public var bootClock: Date? { settings.clock(clockPinned: clockPinned) }

    // MARK: Applying

    /// What this boot last sent; nil until its first apply.
    @ObservationIgnored private var applied: TweakSettings.Applied?
    /// The tweaks the running guest's agent can't apply (an older guest package), for the panel.
    public private(set) var needsNewerGuestTools: [Tweak] = []
    /// The last apply's failure, for the panel.
    public private(set) var failure: String?

    public func forgetBoot() {
        applied = nil
        mountedImage = nil
        needsNewerGuestTools = []
        failure = nil
    }

    // MARK: Developer Settings

    /// The Developer Disk Image this boot mounted (or tried).
    @ObservationIgnored private var mountedImage: String?

    /// Mounts the chosen Developer Disk Image once per boot while Developer Settings is on. A mounted image stays
    /// until the device restarts: the mounter of these versions has no unmount.
    public func mountDeveloperImage(services: DeviceServices) async {
        let settings = settings
        guard settings.isOn(.developerSettings), isAvailable(.developerSettings),
            let path = settings.developerImage, path != mountedImage
        else { return }
        mountedImage = path
        do {
            let mounted = try await services.mountDeveloperImage(URL(fileURLWithPath: path))
            logEvent("tweaks: Developer Disk Image \(mounted ? "mounted" : "already mounted"): \(path)")
            failure = nil
        } catch {
            failure = error.localizedDescription
            logEvent("tweaks: \(error)")
        }
    }

    /// Brings the running guest to the saved settings when they changed since this boot's last apply (or at its
    /// first). `isCurrent` says the boot is still this one.
    public func apply(guest: GuestServices, isCurrent: () -> Bool) async throws {
        guard guestTools else { return }
        let settings = settings
        let target = settings.applied(version: version)
        guard target != applied else { return }
        do {
            let result = try await TweakApplier.apply(
                settings,
                version: version,
                guest: guest,
                again: applied != nil
            )
            guard isCurrent() else { throw CancellationError() }
            applied = target
            needsNewerGuestTools = result.missing
            failure = nil
            if result.written != settings.written { change { $0.written = result.written } }
            if result.resprung { logEvent("tweaks: SpringBoard restarted for \(settings.on.map(\.rawValue).sorted())") }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard isCurrent() else { throw CancellationError() }
            applied = target  // not again every poll: the next change, or the next start, tries again
            failure = error.localizedDescription
            logEvent("tweaks: \(error)")
        }
    }
}
