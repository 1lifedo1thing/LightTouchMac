# Contributing to Light Touch

Light Touch is a native macOS (AppKit) app that runs a library of emulated legacy iOS devices.
The device catalog covers the iPhone (m68ap), iPhone 3GS (n88ap), iPhone 4 (n90ap), iPod touch 1G to 4G
(n45ap, n72ap, n18ap, n81ap) and iPad (k48ap). Each device is prepared
from a stock Apple IPSW by the bundled Swift preparer, `firmwarekit` (`Packages/FirmwareKit`), using
the keys pinned in `LightTouchMac/Resources/firmware-catalog.json`; there are no hand-prepared images
per firmware. Each running device is its own helper process (`LightTouchDevice`), which is the only
thing that links the emulator.

## Firmwares in the catalog

The shared [firmware catalog](LightTouchMac/Resources/firmware-catalog.json) is the source of truth for
builds, availability, keys and preparation recipes. The CLI reads that same catalog:

```sh
firmwarekit create --catalog LightTouchMac/Resources/firmware-catalog.json \
  --id k48ap-7B500 --ipsw /path/to/stock.ipsw --out /path/to/new-device \
  --helper /path/to/LightTouchDevice --guest-tools /path/to/ipad-guest-tools
```

Catalog availability is distinct from measured acceptance.

## The three repositories

| Repo | What it is | How this app uses it |
|---|---|---|
| [LightTouchMac](https://github.com/samhenrigold/LightTouchMac) | This app, the per-device helper, the Swift preparer, the app tests, the product build | — |
| [qemu-ios](https://github.com/samhenrigold/qemu-ios) (branch `main`) | The emulator (`hw/arm/ipod_touch_*.c`, `hw/arm/ipad1.c`, `hw/arm/s5l8930_*.c`), the guest tools under `contrib/` (agent, GL shims, AppSync, guest packages), Python format inspection tools and frozen bake references, and the emulator gates under `tests/` | Pinned by commit in `build-support/sources.json`. Loaded by the helper as `libqemu-arm.dylib` (`contrib/macos-app/make-dylib-macos.sh`), which it refuses unless `qemu_ios_api_version()`'s major matches `Qemu.apiMajor` (bump both when an entry point is removed or changed); its `contrib/export-guest-artifacts.sh` builds and stages the guest tools, GL tables, entitlements and headers with a manifest, and `scripts/build-guest-tools.sh` is a thin caller of it |
| [usbmuxd](https://github.com/samhenrigold/usbmuxd) (fork, branch `idle-poll` on `qemu-zlp`) | The usbmuxd that bridges the emulated USB device to libimobiledevice | Built into the bundle from the commit pinned in `build-support/sources.json`; the emulator and this fork ship together, so bump both pins in one commit |

The emulator side's own entry point is qemu-ios `README.md`.

## Building

Open `LightTouchMac.xcodeproj` in Xcode and build the `LightTouchMac` scheme: the app, the device helper
(`LightTouchDevice`), the services helper (`LightTouchServices`) and the preparer (`firmwarekit`, from
`Packages/FirmwareKit/Sources/FirmwareKitCLI`). The app's one script phase stamps the build number
(`CFBundleVersion`, the commit count).

Debug and Release share `Configuration/Shared.xcconfig`. A Debug helper loads `libqemu-arm.dylib` from a
qemu-ios development build:

```
QEMU_IOS_DIR   = $(HOME)/Developer/qemu-ios-ipad1
QEMU_BUILD_DIR = $(QEMU_IOS_DIR)/build-w1-native          # libqemu-arm.dylib, on a Debug helper's rpath
```

These repeat **the pin**, `build-support/sources.json`: the qemu-ios commit, its expected checkout path and
development build directory, and the usbmuxd commit; iBoot32Patcher is pinned in `build-support/dependencies.json`.
`scripts/sources.py` resolves the pin for every script and check (`sources.py qemu-ios | usbmuxd | qemu-build`,
`sources.py check` for pinned vs actual; `QEMU_IOS_DIR`, `USBMUXD_SOURCE_DIR` and `QEMU_BUILD_DIR` override).
To produce the dylib, build `qemu-system-arm` in that checkout and run `contrib/macos-app/make-dylib-macos.sh BUILD_DIR`.
The services helper links libimobiledevice and libplist: from the vendor directory (below) when there is one,
else Homebrew's. Put local overrides of any of these in `Configuration/Local.xcconfig` (gitignored).

Debug-only knobs (compiled out of Release): `LTM_FIRMWAREKIT=/path/to/firmwarekit` (another preparer),
`LTM_QEMU_DYLIB` (another emulator library), `LTM_USBMUXD` (another usbmuxd). `LTM_STATE_DIR=/dir` keeps all
writable state and logs inside one directory.

## Releases

A release is an Xcode archive; nothing edits the bundle after Xcode.

1. **`scripts/vendor`**, once per pin change (`build-support/sources.json`, `dependencies.json`, the patches or the
   native recipes). It builds what Xcode can't, from the pins, into `~/Developer/ltm-vendor/<pin-hash>/`
   (`LTM_VENDOR_ROOT` moves it; nothing deletes it) and points `Configuration/Vendor.xcconfig` (`VENDOR_DIR`) at it:
   the native dependencies, usbmuxd and QEMU for arm64 and x86_64, merged universal with final install names
   (`Frameworks/`, `MacOS/`), the guest tools and the developer SSH payload packed into
   `Resources/Guest/guest.aar`, the SecureROMs and the built-in iPod (`Resources/Device/`), the licenses and
   `build-inputs.json`. A rerun with nothing changed does nothing; one after a FirmwareKit or helper change only
   prepares the built-in iPod again. Inputs: `ARMV6_SDK` (default
   `~/Developer/ipod2g-re/OldSDK/iPhoneOS3.1.3.sdk`), `LTM_ASSETS` (the SecureROMs, default
   `~/Developer/qemu-ios-files`), the n72ap-7E18 IPSW in the app's IPSW cache, and the network for the pinned
   source archives. Firmware and the iPhoneOS SDK are never downloaded or redistributed.
2. **Xcode ▸ Product ▸ Archive** (scheme `LightTouchMac`, Release, arm64 + x86_64, Developer ID). The archive's
   Copy Files phases bring in the vendor directory (Code Sign On Copy signs its binaries with the app's identity
   and the hardened runtime); only `LightTouchDevice` carries entitlements (`Configuration/LightTouchDevice.entitlements`).
   The scheme's Archive post-action, `scripts/verify-archive`, then checks the archived app: the vendor directory
   matches the pins; every Mach-O signed, hardened, universal, with the declared entitlements and an in-bundle load
   closure; `tests/release/test-package.py` and `test-bundle-hygiene.py`; no code loose under `Resources`; the
   identity scan; and, in-bundle, the bundled `firmwarekit` prepares (or unpacks) each `VERIFY_ENTRIES` device and
   `tests/sessions/check-sessions.py --single` boots it through the bundled helper, dylib, services helper and
   usbmuxd. The verdict is in the archive's Organizer comment and `verify.log`; a failed archive's name ends
   "(VERIFY FAILED)". Xcode does not fail an archive for its post-action, so read the comment before distributing.
3. **Organizer ▸ Distribute App ▸ Direct Distribution** notarizes and exports the app.
4. **`scripts/check-export "path/to/Light Touch.app"`** zips the exported app (ditto) and checks the unzipped copy:
   `codesign --deep --strict`, the stapled ticket, Gatekeeper ("Notarized Developer ID"), slices, entitlements and
   the identity scan. It writes `Light Touch.zip` and `SHA256SUMS` beside the app.

## Gates

One runner, three tiers, and a wrapper that runs the host-only ones:

```sh
tests/run.py offline            # no emulator, about a minute: every tests/offline/check-*.py (swiftc on the app's
                                # sources plus temp fixtures) and the catalog checks, -j 4 through one shared
                                # module cache
tests/run.py release            # packaging and build checks (tests/release/); --network adds the dependency fetch
tests/run.py sessions           # helper + emulator, one boot at a time, -audio driver=none: check-helper-boot,
                                # check-sessions (--ipad-device, then --guest), check-guest-package,
                                # check-activation-gate, check-boot-deadline, check-files-native, check-media-native
scripts/gate.sh --quick         # swift test (Packages/FirmwareKit) + offline + release
scripts/gate.sh --full          # quick + sessions
```

`--only NAME` runs a subset. One line per check (PASS, FAIL, SKIP with the reason, XFAIL for a check
`tests/run.py` lists as known failing on today's code, XPASS once it passes again); non-zero exit only on
FAIL; every log under the printed directory. The sessions tier's inputs (`QEMU_IOS_DIR`, the helper's dylib,
the iPad and iPod device directories, the armv6 package) are documented in `tests/run.py`; a check whose
input is missing is SKIP with the path it wanted; `--require-inputs` makes a selected skip fail acceptance. Every script resolves the qemu-ios and usbmuxd checkouts
through `scripts/sources.py` (the pin in `build-support/sources.json`).

| Directory | What is there |
|---|---|
| `tests/offline/` | One check per topic. Each is standalone; its docstring names what it compiles and its flags. Most compile whole production files with a small fixture; the ones that still cut a section out of a hub file by marker are listed with the reason in [tests/SLICED.md](tests/SLICED.md) |
| `tests/sessions/` | `check-sessions.py` boots two devices at once through the app's own session code (`tests/drivers/session-driver`); `--single DIR --board ipod|ipad` boots one prepared base the way the app does and is what `scripts/verify-archive` runs; `--guest` runs the guest-services scenario. `check-helper-boot.py` drives the helper directly (`tests/drivers/helper-driver`). `matrix.py`, `install-durability.py` and `volume-rebuild-oracle.py` are tools run by hand (`tests/matrix.py` still works) |
| `tests/release/` | Build and packaging checks: dependency sources, guest build, the native merge, Mach-O closures (`test-package.py`, which also checks an app given as its argument), bundle hygiene. `scripts/check-macho.py` and `scripts/test-glib-compat.py` stay in `scripts/` because the native recipe hash includes them |
| `tests/drivers/`, `tests/fixtures/` | The Swift drivers the session checks compile; the fake preparer, the catalog server and the Swift fixtures the checks share |
| `swift test --package-path Packages/FirmwareKit` | FirmwareKit's synthetic unit tests and fixed legacy reference hashes. Optional corpus tests report real skips unless `FK_TEST_CORPUS=1` or `FK_REQUIRE_FIXTURES=1` selects them; selected missing inputs fail. Format/bake oracle checks resolve qemu-ios through `FIRMWAREKIT_QEMU_IOS` |
| `scripts/verify-archive` | The Archive post-action (Releases, step 2); `--static APP` runs its signature, slice and scan checks alone |

Every headless boot passes `-audio driver=none`. The checks are headless; none of them launch the app.

## Boards

A board's facts have two homes. The emulator's: qemu-ios's `qemu_ios_device_info` table
(`contrib/ios-app/qemu-ios-ui.c`): the `-M` machine, the board ID, the screen, the modem, the USB host, the compass,
the USB charger and the `panel=` limits; the helper reports them in its hello and lists them with
`LightTouchDevice --machines`, and the app reads them as `DeviceInfo` (`Board.hardware`). The app's: one `Board`
case and its `Facts` in `Packages/HostRuntime/Sources/HostRuntime/Board.swift`: the names, the model ID, the SoC
family (which decides how its prepared base boots and its guest architecture) and the art. Adding a board touches
those two places; its firmware is catalog entries, and preparing it is a FirmwareKit recipe if no existing one fits.
`tests/fixtures/machines.json` is the listing the tests use without an emulator; `tests/release/test-package.py`
holds each of its machines to the bundled library's.

`device.lock.json` is `DeviceLock` (HostRuntime): FirmwareKit writes it, everything else reads it through that type.

## Rules

- **No Python bridge.** The app runs one preparer, the Swift `firmwarekit`. qemu-ios's Python `imgtools/` is the test oracle, not a runtime.
- **Activation is maintained separately.** FirmwareKit runs it as a built-in preparation step
  (`Packages/FirmwareKit/Sources/CActivation`, `tools/activation/`). Treat it as a black box.
- **No firmware in any repo.** IPSWs, decrypted components, NAND images, SDKs and prepared devices stay
  outside the three repositories; the app downloads or imports them on the user's Mac.
- **Branches.** Both repositories work on `main`. Make a short branch per change and open a pull request;
  `main` doesn't accept force-pushes. A qemu-ios change the app needs lands there first, then the app's
  pin (`build-support/sources.json`) moves to it in the same pull request as the app change.

## Layout

| Path | What |
|---|---|
| `LightTouchMac/` | The app, one directory per layer (below), plus `Resources/firmware-catalog.json` (its `bundled` names the built-in iPod, `Resources/Device/n72ap-7E18.itbase`, which a fresh install unpacks and selects; `first_run` is what a first launch selects without it: an `available` build Apple still serves), `Assets.xcassets`, `Shim/` |
| `LightTouchMac/Transport/` | The wire to a device and the app's logs: `IMobileDevice` (libimobiledevice, linked by the services helper), `USBMux` (each device's usbmuxd), `DeviceExecution` (the serial gate, deadlines, late-handle cleanup, errors, timeouts), `NativeLogging`, `AppEventLog` |
| `LightTouchMac/Services/` | Stock lockdown services on one device, all on `DeviceServices`' `run` kernel: `InstallationProxy`, `AFC` (staging and the Files browser), `SpringBoardServices`, `LockdownTools` (ActivationState; the lockdown-tz and lockdown-mcinstall writes run as child processes of the services helper, `LightTouchServices/Lockdown`), `NotificationProxy` |
| `LightTouchMac/Guest/` | The guest agent: `GuestAgent` (the wire and typed ops), `GuestServices` (media commit, trust, proxy route, respring, launch), `GuestPackage` |
| `LightTouchMac/Library/` | What the app keeps: `DeviceInstance`, `DeviceLibrary`, `DeviceStateStorage`, `StorageLocations`, `Bundled`, `LegacyState`, `IPSWStore`, `FirmwareCatalog`, `FirmwareJobs`, `FirmwareDownloads`, `PreparationJob`, `IPALibrary`, `IPAMembers`, `AppMetadataCache` |
| `LightTouchMac/Device/` | One running device: `Board+App` (what the app derives from a board), `DeviceSession`, `DeviceProcess` (its helper), `EmulatorController` (lifecycle and input; vends `services`, `guest`, `installPipeline`), `DeviceRow`, `DeviceConnectionIssue`, `DeviceFileWatch`, `WebProxyConfiguration` |
| `LightTouchMac/Features/` | What the app does with a device: `AppInstaller` (the per-device install and removal queue), `AppInstallPipeline`, `MediaImport` (+ `Media*`, `PreparedMedia`), `WebProxySetup`, `CaptureController` (+ recording, movie writer, canvas capture, capture preferences), `CatalogClient`/`CatalogCopy`, `DiagnosticsExport` |
| `LightTouchMac/UI/` | Windows, views and view controllers: `MainWindowController`, the sidebar, placeholder, device and inspector view controllers, `DisplayView`, `DeviceModelView`, `DroppedFiles`, the Files, log, storage, proxy and capture panels, small controls |
| `LightTouchMac/App/` | `main`, `AppDelegate`, `MainMenu`, `WindowRestorationPolicy`, `NetworkAccessPreference` |
| `LightTouchDevice/` | The per-device helper: one QEMU instance, frames over IOSurface, control over the `Shared/` link, and the device's web proxy (`WebProxy` on URLSession, `WebProxyAdapters`) behind the 10.0.2.100:3128 guestfwd |
| `Shared/` | The app–helper link (`DeviceLink`, `DeviceLinkProtocol`, `DeviceRendezvous`, the `CLink` module); `WebProxyCA`, the per-device proxy CA both sides use |
| `Packages/FirmwareKit/` | `FirmwareKit` (IPSW → device), the `firmwarekit` CLI (`Sources/FirmwareKitCLI`), `CActivation` |
| `scripts/` | `vendor` (with `build-package-native.sh`, `build-static-deps.sh`, `merge-native.py`, `build-iboot32patcher.sh`, `build-guest-tools.sh`), `verify-archive`, `check-export`, `gate.sh`, `sources.py`, `check-macho.py`, `test-glib-compat.py` |
| `tests/` | `run.py` and the tiers `offline/`, `sessions/`, `release/`; `drivers/` (helper-driver, session-driver), `fixtures/` (fake-firmwarekit.py, catalog-server.py, the Swift fixtures); `SLICED.md` |
| `build-support/` | `dependencies.json` (pinned archives) and build patches |
| `Configuration/` | `Shared.xcconfig` (with the gitignored `Vendor.xcconfig` and `Local.xcconfig`), `LightTouchDevice.entitlements` |
| `Models/` | The 3D device models and their lighting (`Resources/Models/` in the app) |
| `LightTouchServices/` | The services helper: the device services the app asks for, and the lockdown writes (`Lockdown/`) it runs as child processes |
| `spikes/` | Phase-0 spike sources (rendezvous, GL helper, two-at-once); archive material, kept for reference |
| `tools/activation/` | Sam's activation tool (its `build/` output is ignored) |
