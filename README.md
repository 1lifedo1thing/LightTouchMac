# LightTouchMac

A native macOS app that boots and manages an emulated iPod touch 2G (iOS 3.1.3),
built on a [fork of qemu-ios](https://github.com/samhenrigold/qemu-ios).

It is one of three repos that version together:

| Repo | What it is |
|------|------------|
| [LightTouchMac](https://github.com/samhenrigold/LightTouchMac) | This app (AppKit). |
| [qemu-ios](https://github.com/samhenrigold/qemu-ios) | The emulator, loaded as `libqemu-arm.dylib`; also the guest-side helpers the app ships. |
| [usbmuxd-qemu](https://github.com/samhenrigold/usbmuxd-qemu) | Forked usbmuxd that carries USB between the guest and libimobiledevice. |

See [repository layout](docs/repository-layout.md) for source/input ownership
and [macOS storage audit](docs/storage-layout.md) for runtime file locations
and cleanup behavior.

## Kernel diagnostics

Device > Advanced > Kernel Console enables XNU serial logging on the next boot.
Verbose Boot separately controls text on the guest display. Kernel output is
written to the device's `serial.log` and included in Export Diagnostics; it starts
when XNU initializes its serial console, so the earliest kernel banner may not
appear there.

## Music and photo import

Use Apps > Sync Media… or drop MP3, M4A, AAC or WAV audio, or JPEG, PNG or HEIC
photos onto the device. Light Touch
prepares a private copy, checks the codec and duration, and queues the upload
with app installations. Progress appears in the Apps inspector. The guest's
native MusicLibrary service adds each song without replacing the existing
library; imported tracks appear in Music.

AAC, HE-AAC, MP3, Apple Lossless and PCM are accepted with one or two channels at
8–48 kHz. Raw AAC is re-encoded as AAC-LC in an M4A container using macOS audio
codecs; other accepted audio files keep their original bytes. Protected files
and unsupported codecs are rejected before upload.
Cancellation is available during preparation/upload; once “Adding to Music…”
begins the library operation finishes. A failed/uncertain import keeps its
staged audio, and the same staged request can be reconciled without duplication.
Selecting the same source again starts a new import; content-based deduplication,
artwork and playlist editing remain future work.

Photos are oriented upright, reduced to at most 2048 pixels on the longest
edge and converted to baseline JPEG; transparent areas become white. The guest
adds them through its native Saved Photos API, generating its own thumbnails.
A persistent receipt prevents repeating a completed save or blindly replaying
an uncertain save. Separate import jobs still create separate photos.

The product build below compiles the shipped guest helpers from source before packaging.

Validation: tests/check-media-preflight.py, tests/check-upload.py, and the
opt-in tests/check-media-native.py. The native check compiles the production
Swift metadata/upload/import methods, uses real AFC and an isolated guest-agent
adapter, verifies exact bytes and quoted/Unicode metadata, and cleanly shuts
down its guest. Add --photo to check native Saved Photos, or --aac to check raw
AAC conversion and native Music playback. tests/check-photo-preflight.py checks
photo conversion. These tests do not exercise the AppKit picker or drag interaction.

## Battery controls

Device > Battery sets the target level and automatic/forced charging state.
iOS filters battery measurements, so the displayed estimate changes gradually.
The settings also apply at the next boot. Drain accepts 0–100 percent per
emulated minute; 0 disables it. Pausing freezes drain. USB power also freezes
drain unless charging is set to Not Charging. Disconnect USB in the same panel
for normal discharge; iOS can defer voltage measurements while USB is connected
and charging is forced off. Installation and media sync need USB connected.
USB reconnects when the device restarts.

## Building and packaging

The product build supports Apple Silicon and macOS 14 or later. Firmware stays
inside the app in this phase: users do not need to import an IPSW or boot ROM.

Install Xcode and the build tools: Python 3.12 (with QEMU's `distlib`
prerequisite), Meson, Ninja, pkg-config, CMake, autotools/libtool, and `ldid`.
Guest helpers also require your locally installed iPhoneOS 3.1.3 SDK. The SDK
and firmware are external inputs; the scripts do not download or redistribute
an SDK. An old `qemu-ios-deps12` prefix is no longer required.

With the app, QEMU and usbmuxd-qemu checkouts as siblings, and the existing
`qemu-ios-files` folder alongside them, build the complete package with:

```sh
python3 scripts/build-release.py \
  --output .build/releases/local-1 \
  --sdk /path/to/iPhoneOS3.1.3.sdk
```

The output directory must be new. This command builds the pinned native
libraries/client tools, QEMU, the shipped guest helpers and the Release app,
then packages and ad-hoc signs a fresh copy. It produces `Light Touch.app`,
`LightTouchMac.zip`, checksums, a bundle inventory, input/provenance records
and a build log. Generated sources, intermediate outputs and DerivedData stay
under the selected output directory. It never searches arbitrary DerivedData
folders for an app, consumes an older built app, or selects whichever NAND
happens to exist.

The selected NAND defaults to `nand-agent-v4`. `--nand NAME` selects another
existing page directory under `--assets`. The selected firmware is packaged
without modifying the original files or the user's active device state.
Use `--plan` to validate and inspect the selected inputs without writing.

All source locations can be supplied explicitly:

```sh
python3 scripts/build-release.py \
  --output .build/releases/local-2 \
  --qemu-source /path/to/qemu-ios \
  --usbmuxd-source /path/to/usbmuxd \
  --assets /path/to/qemu-ios-files --nand nand-agent-v4 \
  --sdk /path/to/iPhoneOS3.1.3.sdk
```

`--usbmuxd-source` points to the actual fork's source directory (the legacy
layout is `usbmuxd-qemu/usbmuxd`). No files from its runtime `run/conf` directory
are packaged; the app receives an empty configuration seed and generates its
own host identity in writable state.

For subsequent builds, `--native-build PATH` reuses a native work directory
created by the new builder and rebuilds QEMU before packaging. A complete
`native-build.json` is required so reuse can validate the source/dependency
inputs. `--guest-tools PATH` similarly reuses the flat `guest-tools` directory
from the guest builder only when its recorded inputs and outputs still match.
`--source-packages PATH` can reuse an Xcode SourcePackages cache. Local source
changes are recorded; these records do not claim an uncommitted tree is a
published, reproducible release revision.

The lower-level steps remain available:

```sh
# Fresh dependency/emulator build, with its own recorded inputs.
scripts/build-package-native.sh .build/native
# Fresh guest-only build. Payloads appear under .build/guest/guest-tools.
ARMV6_SDK=/path/to/iPhoneOS3.1.3.sdk scripts/build-guest-tools.sh .build/guest
# Package an explicitly selected Release app, using declared input overrides.
QEMU_BUILD_DIR="$PWD/.build/native/qemu-build" \
LTM_DEPS_PREFIX="$PWD/.build/native/prefix" \
LTM_STATIC_DEPS="$PWD/.build/native/static/prefix" \
USBMUXD_BIN="$PWD/.build/native/build/usbmuxd/src/usbmuxd" \
LTM_GUEST_TOOLS_DIR="$PWD/.build/guest/guest-tools" \
  scripts/package.sh /path/to/Light\ Touch.app
```

Dependency archive versions/hashes live in `build-support/dependencies.json`.
`LTM_SOURCE_CACHE` selects a directory of archives to reuse after checksum
verification; `LTM_OFFLINE=1` refuses missing archives instead of downloading.
`LTM_JOBS` limits compiler parallelism. An explicitly supplied `LTM_STATIC_DEPS`
can reuse a compatible prefix; its contents are recorded, and it is never
silently selected from a private build job. `CMAKE`, `MESON`, and `QEMU_PYTHON`
select installed build tools when they are not on the usual PATH.

## Xcode development builds

Debug and Release share `Configuration/Shared.xcconfig`. `QEMU_IOS_DIR` defaults
to the sibling QEMU checkout and `QEMU_BUILD_DIR` to its existing
`build-native14/qemu-build` directory. Override either build setting for a
product-owned `.build/native` directory or a different checkout. Header paths,
linkage and runtime search paths follow those settings, including paths with
spaces. The app's macOS deployment floor remains 14.0.

The project has no shell build phases. Ordinary Xcode builds compile the app;
they do not download dependencies, rebuild the emulator or package firmware.
Use the explicit product builder for packaging. After emulator-only changes,
run Ninja and `contrib/macos-app/make-dylib-macos.sh` in the selected native
build before compiling the app in Xcode.

## Signing and validation

The default package uses ad-hoc signing for local testing. Pass
`--sign-id "Developer ID Application: …"` for your distribution identity and
`--notary-profile PROFILE` to submit/staple through your existing notarytool
keychain profile. No credentials are stored in the scripts. Packaging validates
host architecture, minimum macOS version and the relocated dependency closure
before signing, including the libraries opened dynamically by the app.

Ad-hoc helper signatures use ordinary code signing because they have no Team
ID. Developer ID builds enable the hardened runtime for helpers and sign their
bundled libraries with the same identity; helper library validation stays
enabled. Apple documents the [same-Team-ID library validation rule](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation).
The signing test launches a relocated helper linked to a bundled test library.
It can also exercise your real identity with
`python3 scripts/test-signing.py --sign-id "Developer ID Application: …"`.

Run the focused build/package checks:

```sh
python3 scripts/test-dependency-sources.py
python3 scripts/test-guest-build.py
python3 scripts/test-release.py
python3 scripts/test-package.py
python3 scripts/test-signing.py
python3 scripts/test-glib-compat.py
python3 tests/check-package-layout.py
python3 tests/check-storage-lifecycle.py
```

Native builds also exercise GLib’s pipe fallback and reject unexpected weak
imports in C helpers/libraries. A small GLib probe patch preserves SDK API
availability annotations so a newer SDK cannot silently select `pipe2` for
the macOS 14 deployment target. `test-glib-compat.py --native-build PATH`
checks the resulting native artifacts as well as the compiler probe.

The driver always includes firmware. Direct `package.sh` retains
`LTM_ASSETS=none` solely for development and clears any previous device payload
when that option is selected; it does not add a consumer import flow.

## Device assets

The emulator boots real iPod touch 2G firmware (bootrom, iBoot, NOR) and a
prepared iOS 3.1.3 NAND image. These are Apple-copyrighted and are not in any
of the three repos; a packaged app embeds your local copies from the selected
`qemu-ios-files` input directory. The app never writes to the base image — per-user
state (NAND overlay and snapshots) lives in
`~/Library/Application Support/gold.samhenri.LightTouchMac`. The previous
`LightTouchMac` directory migrates on launch; conflicting directories stop startup
with an error so neither device is silently replaced. App, serial, usbmuxd and
native diagnostics live in `~/Library/Logs/gold.samhenri.LightTouchMac`, with a
bounded current and previous file for each stream. Device Logs and Export
Diagnostics use those locations. `LTM_STATE_DIR` keeps both state and logs inside
the supplied directory for isolated development and tests.


### Catalog and installation reliability (2026-09-04)

The Store keeps `/api/emulator/apps` for its compatibility-filtered catalog.
“Versions and Details…” uses the public versions/copy APIs; each selected copy
is revalidated against the emulator endpoint, then checked for size and archive
MD5 before installation. These checks do not establish runtime compatibility.

Downloads run independently; only completed IPAs enter the serial device queue.
A device/transfer failure pauses pending installs while retaining their downloaded
files. Use “Resume Pending Installs” in the app-list context menu after the device
responds, or cancel individual jobs. Open/Uninstall remain available during network
downloads, but wait while a device operation is active. Store rows also expose
Open/Uninstall for installed apps. Selection tracks stable row identities.

Run the isolated checks (no QEMU or existing device state is used):

```sh
python3 tests/run-catalog-checks.py
python3 tests/run-catalog-checks.py --ui  # also briefly presents an AppKit test sheet
```

Tilt counter-rotation now follows only the guest orientation, so a layout during
a gesture cannot leave the screen crooked. Quit no longer attempts a UI power-off
swipe. Native shutdown now follows SpringBoard’s launchd-coordinated `reboot2`
path and passes actual PMU confirmation. Warm-reset storage mapping and watchdog
command handling are corrected in QEMU; the app no longer suppresses resets.
The `boot,restart,persist,fsck` regression passes with byte-identical markers
and a full-volume filesystem check. A helper banner remains insufficient proof
of shutdown.

Outstanding reports: Spore’s black MPEG-4/AAC intro, silent PCM game music, missing
video-player status bar still require further guest/emulator diagnosis. The
status bar appeared in an isolated movie-player run, so that omission is not
universal. Native reboot and post-media warm reset now pass. The current hardware model does not implement the video
decoder or full AMC compressed-audio processing. These are not claimed fixed by
the frontend changes.


Power Off in the Lock toolbar menu shuts down the guest and leaves the window
open. Power On cold-boots the same emulator instance. A dimmed device with a
Sleeping or Powered Off badge distinguishes these states from an unresponsive
frame; Wake Up uses the power button. The window subtitle follows SpringBoard's
localized foreground app name (Home Screen when no app is foreground).

For isolated development runs, `LTM_STATE_DIR=/absolute/test/path` redirects
all writable device state, logs and usbmuxd scratch from Application Support.
The default remains the existing user state directory.

### Web and captures

Device > Proxy offers No Proxy or HTTP Proxy, with an optional archive date.
The proxy is bundled: no separate server or installation is required. Dated
browsing fetches the closest available Internet Archive capture through verified
host HTTPS. Changes apply when the guest is awake and ready; No Proxy restores
its previous proxy keys and removes the device-local proxy certificate. HTTPS
uses a built-in TLS bridge: the guest trusts a unique certificate for its own
proxy, while the Mac verifies the real site's modern TLS connection. No Mac
certificate installation is needed. Archive availability/rate limits and the
old browser's JavaScript/CSS limitations still apply.

Capture provides Save Screenshot (Shift-Command-S), Live Text
(Shift-Command-L), and Start/Stop Recording (Shift-Command-R). Screenshots use
the native screen pixels, including while paused. Live Text freezes the image inline inside the device screen for selection and
data detectors; Done or Escape returns to the live guest. Show Finger Dots uses
44-point soft gradient indicators with shadows and a 160 ms release fade in the
preview, screenshots and recordings. Touches do nothing while sleeping or off.
The sleeping presentation uses the bundled Sleeping.caar animation.

Recordings use H.264 video at the native screen dimensions. A recording that
changes orientation uses a 480 × 480 canvas with black margins. The Record
button turns red while recording, without shifting the toolbar. Screenshots
and finished movies save automatically to Downloads/Light Touch; Capture
includes commands to choose another folder and reveal it in Finder. Recordings include the device’s stereo audio, including silent timing gaps while
the emulator is paused.


Device Logs includes app events, device console output, and USB service logs.
App events are written off the main thread with a 32 KB per-entry limit and
one current/one previous 1 MB file. Export Diagnostics includes those files.
Preparation, save-state, erase, and shutdown failures appear in a persistent
status bar with Show Logs and Dismiss. Successful retries clear the matching
status; an active storage-write failure takes priority and cannot be dismissed.
