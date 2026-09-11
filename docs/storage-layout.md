# Runtime storage

This inventory covers the Mac app and helpers it invokes. It is based on source
inspection, not private runtime file contents. The app continues to ship its
device assets in one package; firmware import is a separate future change.

Apple recommends Application Support for app-managed durable data, Caches for
recreatable support data, and the system temporary directory for short-lived
work. Temporary and cache contents must be safe to lose. The app should remove
temporary files when their work finishes; system cleanup has no guaranteed
schedule. See [Using the file system effectively](https://developer.apple.com/documentation/foundation/using-the-file-system-effectively).

## Current locations and ownership

`State` below means `~/Library/Application Support/LightTouchMac`. An explicit
`LTM_STATE_DIR` replaces that root for development and verification. Existing
durable state stays at this established location; this cleanup does not rename
the whole directory to the bundle identifier.

| Location | Contents and purpose | Lifetime and cleanup |
| --- | --- | --- |
| App bundle, `Contents/Resources/device` | Boot assets and packed NAND supplied with this release | Read-only inputs; never used as writable device storage. |
| `State/device/active-<nand>.json` | Active base image pointer | Retained across app moves and upgrades. |
| `State/device/<nand>-<digest>`; legacy `State/device/<nand>` | Extracted, immutable NAND base | Retained while a device depends on it. An existing device keeps its original base after an app update. |
| `State/nandrw-<image-key>` | Writable NAND pages and private `nor.bin` | Durable user device data. Erase removes the selected overlay before the next boot. Ordinary shutdown and failed snapshots do not delete it. |
| `State/snapshot-<image-key>`, `.meta`, `.tmp`, `.bad` | Saved RAM, identity metadata, staging, and quarantine | At most one saved and one quarantined snapshot per key. Explicit discard removes these and their metadata, not the overlay. Resume is currently disabled in the controller. Old image generations are not automatically collected. |
| `State/IPAs/<bundle-id>.ipa` | A retained copy of an installed archive, used to drag installed apps out as files | Adopted after successful install via a temporary sibling and atomic rename. Removed after successful uninstall through the app. These copies serve a feature and are not disposable download scratch. |
| `~/Library/Caches/gold.samhenri.LightTouchMac/AppMetadata` | Installed-app display names, icons, and `index.json` | Disposable metadata. An isolated run uses `State/Caches/AppMetadata`. Missing metadata falls back to the device-reported name; installs populate the cache again. |
| `State/AppCache` | Legacy metadata location | Moved atomically to the new cache when no destination exists. See migration exceptions below. |
| `State/work/usbmuxd-conf` | System configuration and device pairing records | Durable daemon state, copied from bundled seed once. Keep across launches; never include in a generic scratch-directory deletion. |
| `State/work/session.env`, `usbmuxd.pid` | Helper connection information and owned daemon PID | Rewritten for a new session. Stop removes the PID; stale-daemon recovery uses it after an interrupted app run. `session.env` remains until overwritten. |
| `State/app.log`, `.1` | App events | Current plus previous generation; each is approximately 1 MB, with bounded individual messages. |
| `State/serial.log`, `.1`; `State/work/usbmuxd.log`, `.1` | QEMU serial and USB daemon output | One previous generation, rotated before the writer opens the new log. Each running session can still grow without a byte limit. |
| `State/web-proxy.json`, `web-proxy.conf` | UI preferences and the helper's plain-text routing representation | Two intentional representations of the same setting, written atomically. |
| `State/web-proxy.conf.ca.pem`, `.ca.der`, `.ca.lock` | Proxy CA identity, exported certificate, and lock | Persistent identity reused across launches; guest trust refers to this certificate. Do not treat as cache or change its lifetime casually. |
| `State/web-proxy.conf.archive-gate`, `.archive-cache-XX` | Request cooldown and archived-response cache | 64 slots, each capped near 2 MiB, roughly 128 MiB total. Responses expire logically after a day; slot files remain until replaced. |
| `State/work/catalog-<id>-<UUID>` | Completed catalog downloads awaiting installation | The install job removes its directory on normal success, failure, or cancellation. An abrupt process exit can leave completed downloads here. |
| System temporary directory: `ltm-music-<UUID>`, `ltm-photo-<UUID>`, `ltm-fixed-<UUID>.ipa` | Media preparation and repaired install archive | Operation-owned; cleanup covers normal completion, failure, and cancellation. |
| System temporary directory: `<UUID>.mov`, `.capture-<UUID>.mov` | In-progress recordings and cropped replacements | Successful export removes temporary output. Export errors deliberately retain the original recording as a recovery file and show its path. |
| System temporary directory: `LightTouch-diagnostics-<UUID>` | One diagnostics export's copied logs and provenance | Unique per export; removed after success, failure, or cancellation, after its archiver has stopped. |
| System temporary directory: `itssh` directory and command file | Terminal handoff script | Outer script cleans up failed handoff; generated command takes ownership after successful handoff and cleans up on completion. |
| Downloads/Light Touch, or user-selected capture folder | Screenshots and completed recordings | User output, not app cache. Names contain timestamps and random suffixes. Never removed by device erase or cache cleanup. |
| User-selected export destinations | Device files and diagnostics ZIPs | Published from completed adjacent staging files. Failed/cancelled diagnostics exports preserve an existing destination. |
| System preferences | UI settings and window state | Managed through `UserDefaults` and AppKit; no manually written Preferences files. |

URLSession may also manage its own HTTP cache and temporary downloads. The app
uses the standard session APIs rather than naming or sweeping those files.
`/tmp/ltm-*`, `/tmp/itorient`, media staging, and similar paths inside guest
commands belong to the emulated device, not the Mac's `/tmp` directory.

## Changes made in this cleanup

- Metadata uses the standard Caches location and respects `LTM_STATE_DIR`.
  Migration moves only the owned legacy `AppCache`, with no duplicate on normal
  success. If migration fails, the original remains usable. If both locations
  already exist, current metadata wins and legacy `State/AppCache` remains for
  conflict review; merging potentially different indexes is intentionally not
  guessed. No complete state-directory deletion is involved.
  Each icon/index write recreates its cache directory if it was purged while the
  app was running, then publishes the file atomically.
- NAND extraction removes its `.partial` directory after a failed helper
  launch, failed extraction, or failed publication. A retry must successfully
  remove abandoned partial output before beginning. The helper also reports
  deferred output errors instead of publishing a truncated base as successful.
- Diagnostics uses a unique temporary workspace, checks subprocess success,
  waits for child termination on cancellation, and atomically publishes the
  finished archive on the destination volume. Repeated exports cannot delete
  each other's working directories. Errors reach the UI.
- The Terminal helper now cleans up failed launch handoff. The proxy cache
  publishes complete entries atomically and removes its own temporary file on
  ordinary write/close/rename failure; cache misses do not create empty slots.

Forced termination or a system crash can interrupt cleanup. Unique temporary
names keep such remnants separate from complete data; no broad startup sweep
was added that could delete another running process's files. Adjacent export
staging files can remain in a chosen destination directory after a hard kill.

## Backup and disk-space policy

The extracted NAND duplicates material in the shipped app, but it is **not
currently a safely disposable cache**. After an app update, an existing overlay
may still depend on the old extracted base, which the updated app no longer
contains. Back up the base, active pointer, and writable overlay together.
Do not blanket-exclude extracted bases from Time Machine or move them into
purgeable Caches until there is a verified way to reproduce every referenced
base. No backup exclusion was added to those paths.

Backups taken while the guest is writing are not a verified coherent device
snapshot. Stop the device/app before a manual state backup. A restored RAM
snapshot may fail its inode/build/base checks and cold-boot; the overlay remains
the durable device data. Pairing records, proxy CA identity, and retained IPAs
also have durable roles and should not be erased to reduce apparent duplication.

The metadata cache is allowed to disappear: the app can operate without it.
Apple advises excluding recreatable data from backups, but that classification
must follow actual recoverability, especially for large support files. See
[Using the file system effectively](https://developer.apple.com/documentation/foundation/using-the-file-system-effectively)
and [backup exclusion semantics](https://developer.apple.com/documentation/foundation/urlresourcevalues/isexcludedfrombackup).

There is no global storage budget or automatic cleanup of old device generations.
Keeping old base/overlay pairs is deliberate protection against data loss. A
future storage-management screen should show their sizes and dependencies and
offer explicit removal of an unused device generation as a pair. Reducing the
download size through user-supplied firmware is a separate effort.

## Remaining focused follow-ups

1. **Separate mixed-lifetime work and logs.** `work` currently contains pairing
   records, per-run connection files, and disposable downloads. Move only
   short-lived jobs to owned temporary directories. Give logs a dedicated
   `~/Library/Logs/gold.samhenri.LightTouchMac` location with compatible diagnostic
   and helper references, and bound long-running serial/usbmuxd output. Apple
   identifies Logs as the conventional log location in
   [macOS Library Directory Details](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/MacOSXDirectories/MacOSXDirectories.html).
2. **Move only proxy response cache data to Caches.** The helper currently
   derives cache, certificate, and cooldown paths from one config filename.
   Splitting these needs explicit helper path inputs and migration; moving the
   whole set would incorrectly make persistent CA identity disposable. Atomic
   cache publication is fixed without changing these paths.
3. **Make recording recovery durable.** A failed export leaves a recovery movie
   in the system temporary directory. Preserve recoverable recordings in an
   app-managed recovery location, then offer reveal/retry/discard; do not sweep
   these files as if they were failed disposable work.
4. **Clarify library ownership for multiple device images.** Overlays are keyed
   per image, while `IPAs/<bundle-id>.ipa` and metadata are app-wide. Installing
   another version replaces that preserved archive; uninstalling from one image
   deletes the shared copy. Before exposing multiple independent devices,
   namespace references per device or retain content-addressed archives with
   references. Do not delete shared IPAs during device-reset cleanup.
5. **External install wrapper scratch.** The external/non-baked
   `qemu-ios-files/apps/install-app.sh` creates work or fallback temporary space
   even when it immediately hands off to the actual installer. It should resolve
   the existing session path without creating an unowned directory. The current
   default packaged device does not invoke this wrapper.
6. **Atomic daemon pairing writes.** The pinned usbmuxd implementation removes
   a prior pairing/configuration file before writing its replacement. A later
   dependency patch should atomically replace these files inside its configured
   app-owned directory. It does not use the Mac's shared pairing directory.

## Source references and validation

- [Path ownership](../LightTouchMac/Bundled.swift),
  [metadata migration](../LightTouchMac/AppMetadataCache.swift),
  [device-state persistence](../LightTouchMac/DeviceStateStorage.swift),
  [controller extraction and lifecycle](../LightTouchMac/EmulatorController.swift).
- [Diagnostics and captures](../LightTouchMac/MainWindowController.swift),
  [file export](../LightTouchMac/DeviceFiles.swift),
  [retained IPAs](../LightTouchMac/IPALibrary.swift),
  [download ownership](../LightTouchMac/CatalogClient.swift),
  [install cleanup](../LightTouchMac/AppsInspectorViewController.swift).
- [USB daemon state](../LightTouchMac/USBMux.swift),
  [proxy settings](../LightTouchMac/WebProxyConfiguration.swift),
  [helper environment](../LightTouchMac/DeviceTools.swift).
- [Focused storage lifecycle check](../tests/check-storage-lifecycle.py) compiles
  production helpers under Swift 6 with MainActor defaults. It covers cache
  migration/isolation/failure and recovery after a purge, partial extraction
  cleanup, real ZIP contents, concurrent exports, cancellation and child teardown, preservation of existing
  destinations, and cleanup of owned staging. It creates only isolated fixtures
  and does not launch QEMU or inspect private user state.
