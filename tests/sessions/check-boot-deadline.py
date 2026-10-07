#!/usr/bin/env python3
"""A boot that never lights ends as a named error with the helper halted, never "Booting…" forever.

The offline half (the boot watch's deadline, recovery mode, missing boot files, the serial watch across
writes) is LightTouchCoreTests' BootWatchTests and BootStageTests, on Session/BootWatch.swift; --offline is a
no-op kept for tests/run.py.

With --recovery-device (default: the stale device.py iPod 4.2.1 base, which iBoot leaves in
recovery mode), the session driver boots it with the app's serial watch and must see the marker
long before the budget, then halt the helper.

    tests/sessions/check-boot-deadline.py [--offline] [--recovery-device DIR --board ipod|ipad] [--helper PATH] [--dylib PATH] [--work DIR]
"""
import argparse, importlib.util, json, os, signal, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HOME = Path.home()
sys.path.insert(0, str(ROOT / "scripts"))
import sources  # the pinned checkouts (build-support/sources.json)
DEFAULT_DEVICE = HOME / "Developer/qemu-ios-files/ipod-ipsw/devices/8C148-b"


def live(args):
    spec = importlib.util.spec_from_file_location("check_sessions", ROOT / "tests/sessions/check-sessions.py")
    sessions = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(sessions)
    work = args.work or Path(tempfile.mkdtemp(prefix="ltm-deadline-"))
    work.mkdir(parents=True, exist_ok=True)
    print(f"work: {work}", flush=True)
    helper = sessions.build(args, work)
    cfg = {"helper": str(helper), "requirement": sessions.helper_requirement(args), "usbmuxd": args.usbmuxd, "ipa": "", "bundleID": "",
           "work": str(work), "files": str(args.files), "ipodNAND": "",
           "ipadBase": str(args.recovery_device if args.board == "ipad" else ""),
           "deadline": {"board": args.board, "base": str(args.recovery_device), "budget": args.budget}}
    (work / "config.json").write_text(json.dumps(cfg, indent=1))
    driver = subprocess.Popen([work / "session-driver", work / "config.json"], stdout=open(work / "driver.jsonl", "w"),
                              stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=dict(os.environ, LTM_QEMU_DYLIB=args.dylib))
    events = []
    try:
        try:
            driver.wait(timeout=args.budget + 90)
        except subprocess.TimeoutExpired:
            driver.kill()
            driver.wait()
    finally:
        for line in (work / "driver.jsonl").read_text(errors="replace").splitlines():
            try:
                events.append(json.loads(line))
            except ValueError:
                events.append({"event": "text", "text": line})
        pids = {e["pid"] for e in events if e.get("event") in ("hello", "booted", "usbmuxd") and e.get("pid")}
        if (work / "pids").exists():
            pids |= {int(x) for x in (work / "pids").read_text().split()}
        for pid in pids:
            try:
                os.kill(pid, signal.SIGKILL)
                print(f"  (killed leftover {pid})")
            except (ProcessLookupError, PermissionError):
                pass
    one = lambda name: ([e for e in events if e.get("event") == name] or [{}])[0]
    results = []

    def check(ok, what):
        results.append(bool(ok))
        print(f"  {'ok ' if ok else 'FAIL'} {what}", flush=True)

    out = one("outcome")
    check(out.get("outcome") == "recovery", f"the serial watch saw \"Entering recovery mode\" after {one('recovery').get('seconds', -1):.1f} s "
          f"(outcome {out.get('outcome')!r} at {out.get('seconds', -1):.1f} s of a {out.get('budget', 0):.0f} s budget)")
    check(one("quit").get("exited"), f"the helper halted in {one('quit').get('seconds', -1):.1f} s: {one('quit').get('reason')!r}")
    check(one("done") and driver.returncode == 0, f"driver finished (exit {driver.returncode})")
    fails = [e for e in events if e.get("event") == "fail"]
    if fails:
        print("  driver: " + fails[0]["why"])
    print(f"\n{sum(results)}/{len(results)} passed; events {work}/driver.jsonl")
    return all(results)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--offline", action="store_true", help="the offline half is LightTouchCoreTests now: a no-op")
    ap.add_argument("--recovery-device", type=Path, default=DEFAULT_DEVICE, help="a base iBoot leaves in recovery mode")
    ap.add_argument("--board", choices=("ipod", "ipad"), default="ipod")
    ap.add_argument("--budget", type=float, default=120, help="seconds to allow the marker (the app's budget is the board's)")
    ap.add_argument("--helper")
    ap.add_argument("--dylib", default=os.environ.get("LTM_QEMU_DYLIB", str(sources.qemu_build() / "libqemu-arm.dylib")))
    ap.add_argument("--files", type=Path, default=HOME / "Developer/qemu-ios-files")
    ap.add_argument("--usbmuxd", default=str(sources.path("usbmuxd") / "src/usbmuxd"))
    ap.add_argument("--work", type=Path)
    args = ap.parse_args()
    if args.offline:
        print("ported to LightTouchCoreTests")
        return 0
    if not args.recovery_device.is_dir():
        print(f"no recovery base at {args.recovery_device}: nothing to boot")
        return 0
    return 0 if live(args) else 1


if __name__ == "__main__":
    sys.exit(main())
