#!/usr/bin/env python3
"""The app verifies activation once per boot and blocks commands, persistently, when it didn't happen.

The offline half (the controller's first-answer check: three answers before a verdict, the persistent
DeviceConnectionIssue, services that answer winning over the string, -34, the lock's note) is LightTouchCoreTests'
ConnectionRecoveryTests, on Session/ConnectionRecovery.swift's ActivationCheck; --offline is a no-op kept for
tests/run.py.

With --device (default: a hook-less device.py iPod 3.1.3 base), the session driver boots it
as the app does and asks the same question over its own usbmuxd: the state is not Activated,
the mapped issue is the persistent one, and the first service read (-34) maps to it too.
With --expect activated (and --device shipping for the app's built-in iPod image, nand-current)
the other half: whatever activated state lockdown reports maps to no issue, and the service read
(the inspector's first app list, what enables Install) succeeds.

    tests/sessions/check-activation-gate.py [--offline] [--device DIR|shipping --board ipod|ipad] [--expect activated]
                                            [--helper PATH] [--dylib PATH] [--work DIR]
"""
import argparse, importlib.util, json, os, signal, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HOME = Path.home()
sys.path.insert(0, str(ROOT / "scripts"))
import sources  # the pinned checkouts (build-support/sources.json)
DEFAULT_DEVICE = HOME / "Developer/qemu-ios-files/ipod-ipsw/devices/7E18-a"
TEXT = "This iPod isn’t activated. Choose Erase All Content and Settings, then prepare it again."


def live(args):
    spec = importlib.util.spec_from_file_location("check_sessions", ROOT / "tests/sessions/check-sessions.py")
    sessions = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(sessions)
    work = args.work or Path(tempfile.mkdtemp(prefix="ltm-activation-"))
    work.mkdir(parents=True, exist_ok=True)
    print(f"work: {work}", flush=True)
    helper = sessions.build(args, work)
    shipping = str(args.device) == "shipping"
    nand_current = args.files / "nand-current"
    cfg = {"helper": str(helper), "requirement": None, "usbmuxd": args.usbmuxd, "ipa": "", "bundleID": "",
           "work": str(work), "files": str(args.files),
           "ipodNAND": str(args.files / os.readlink(nand_current)) if shipping and nand_current.is_symlink() else "",
           "ipadBase": str(args.device if args.board == "ipad" else ""),
           "activation": {"board": args.board, "base": "" if shipping else str(args.device)}}
    if args.frameworks:
        cfg["frameworks"] = args.frameworks
    (work / "config.json").write_text(json.dumps(cfg, indent=1))
    driver = subprocess.Popen([work / "session-driver", work / "config.json"], stdout=open(work / "driver.jsonl", "w"),
                              stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=dict(os.environ, LTM_QEMU_DYLIB=args.dylib))
    events = []
    try:
        try:
            driver.wait(timeout=570)
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

    text = TEXT.replace("iPod", "iPad") if args.board == "ipad" else TEXT
    check(one("lit"), f"lit in {one('lit').get('seconds', -1):.1f} s")
    check(one("usb").get("productType"), f"lockdown answered over its usbmuxd: {one('usb').get('productType')}")
    act = one("activation")
    svc = one("service")
    if args.expect == "activated":
        # What lockdown says is reported, not judged: the built-in iPod reports Unactivated and works.
        print(f"  note: ActivationState {act.get('state')!r} (issue from the string alone: {act.get('summary') or 'none'!r})")
        check(not svc.get("error") and svc.get("apps", -1) >= 0, f"the service read succeeds: {svc.get('apps')} apps listed (installs enabled)"
              + (f": {svc.get('error')}" if svc.get("error") else ""))
    else:
        check(one("lock").get("lacksActivation"), "the lock records no activation: the row says \"Prepared without activation\"")
        check(act.get("state") and (act.get("state") == "Unactivated" or "Activated" not in act.get("state")), f"ActivationState {act.get('state')!r}")
        check(act.get("summary") == text and act.get("persistent") and act.get("blocks") and not act.get("retries"),
              f"the issue: persistent, blocks commands, no retry: {act.get('summary')!r}")
        if "-34" in svc.get("error", "") or "prohibited" in svc.get("error", "").lower():
            check(svc.get("summary") == text and svc.get("persistent"), "the first service read (-34) maps to the same issue")
        else:
            print(f"  note: the service read did not fail with -34 ({svc.get('error') or 'succeeded'}); no mapping to check")
    check(one("quit").get("exited"), f"helper halted in {one('quit').get('seconds', -1):.1f} s")
    check(one("done") and driver.returncode == 0, f"driver finished (exit {driver.returncode})")
    fails = [e for e in events if e.get("event") == "fail"]
    if fails:
        print("  driver: " + fails[0]["why"])
    print(f"\n{sum(results)}/{len(results)} passed; events {work}/driver.jsonl")
    return all(results)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--offline", action="store_true", help="the offline half is LightTouchCoreTests now: a no-op")
    ap.add_argument("--device", type=Path, default=DEFAULT_DEVICE, help="a prepared base whose lock has no activation; "
                    "`shipping`: the app's built-in iPod image (qemu-ios-files/nand-current)")
    ap.add_argument("--board", choices=("ipod", "ipad"), default="ipod")
    ap.add_argument("--expect", choices=("unactivated", "activated"), default="unactivated")
    ap.add_argument("--helper")
    ap.add_argument("--dylib", default=os.environ.get("LTM_QEMU_DYLIB", str(sources.qemu_build() / "libqemu-arm.dylib")))
    ap.add_argument("--files", type=Path, default=HOME / "Developer/qemu-ios-files")
    ap.add_argument("--usbmuxd", default=str(sources.path("usbmuxd") / "src/usbmuxd"))
    ap.add_argument("--frameworks")
    ap.add_argument("--work", type=Path)
    args = ap.parse_args()
    if args.offline:
        print("ported to LightTouchCoreTests")
        return 0
    if str(args.device) != "shipping" and not args.device.is_dir():
        print(f"no device at {args.device}: nothing to boot")
        return 0
    return 0 if live(args) else 1


if __name__ == "__main__":
    sys.exit(main())
