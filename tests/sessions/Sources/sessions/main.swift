import Foundation

let usage = """
    usage: swift run --package-path tests/sessions sessions <check> [BASE …] [options]

    Every boot is headless and silent (-audio driver=none); nothing goes on screen. A BASE is a prepared device
    (firmwarekit create output); it is read only. Exit 1 on any FAIL.

      single BASE          one device as the app boots it: lit, lockdown, activation, time zone, the Home screen (agent
                           state, frame reference), backlight, AFC, an IPA install, a clean shutdown, the base untouched
          --launch           launch the installed IPA through the guest agent; it must be frontmost
          --reboot           a second cold boot on the same overlay: a file and the app must survive
          --read-file PATH   the guest agent reads PATH back at Home
          --upgrade-ipa IPA  install a newer build of the same app over it; its data must stay
          --second-zone TZ   with --reboot: boot 2 asks for TZ
          --host-power-gesture   shut down with the host's power gesture (iPod/1G)
          --afc-race N [--dirty] N boots, AFC at lockdown's first answer, then Stop
          --no-install --no-offer --ipa IPA --itpack PACK --audio-wav FILE
      pair N72_BASE K48_BASE   two devices at once: kill -9 of one, restart, Stop both
      proxy-trust BASE     the web proxy's CA trusted silently (n72 or k48)
      local-network BASE   Attach to Local Network off: internet yes, the Mac's LAN no, until turned on (n72)
      helper               the helper without a guest: signature pin, leases, kill before hello, preparation failure
      helper-boot BASE     the helper alone on an n72 base: input, rotation, parent death, a meddled overlay, power (--only)
      phone BASE           an iPhone base: carrier (SMS tone, ringtone), rotate, shutdown, keyboard (--only, --overlay DIR)

    Inputs: --app "Light Touch.app" boots with a built app's helper, services worker, firmwarekit, dylib, usbmuxd and
    guest package; without it the Debug helper, services worker and firmwarekit are built (cached in .build/sessions-xcode)
    and scripts/vendor's directory supplies the rest. --dylib, --usbmuxd, --httpget override; --work DIR keeps the logs,
    screenshots and events (default: a temporary directory).
    """

// App code in the drivers logs and keeps state under the run's own directories, never the user's library.
setenv("LTM_STATE_DIR", FileManager.default.temporaryDirectory.appendingPathComponent("ltm-sessions-state").path, 1)

let flags: Set<String> = ["launch", "reboot", "no-install", "no-offer", "dirty", "host-power-gesture"]
let all = Array(CommandLine.arguments.dropFirst())
guard let check = all.first, check != "--help", check != "-h" else {
    print(usage)
    exit(all.isEmpty ? 2 : 0)
}
let args = Arguments(Array(all.dropFirst()), flags: flags)
switch check {
case "single": single(args)
case "pair": pair(args)
case "proxy-trust": proxyTrust(args)
case "local-network": localNetworkCheck(args)
case "helper": helperChecks(args)
case "helper-boot": helperBoot(args)
case "phone": phone(args)
default:
    print(usage)
    exit(2)
}
