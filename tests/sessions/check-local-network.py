#!/usr/bin/env python3
"""Attach to Local Network, off by default: the guest reaches the internet but not the Mac's LAN until it is turned on.

One iPod boots as the app does (the session driver's proxy.swift with `lan`): the helper's web proxy on the wifi
guestfwd and slirp's lan=off. A listener on this Mac's LAN address stands in for a LAN host. The guest's httpget
(CFNetwork; the image's PAC sends private addresses DIRECT, so slirp carries it) fetches a public page (through
the proxy) and the listener; the listener must see nothing. Then `.netLocalNetwork(true)` (qemu_ios_ui_net_lan,
in place) and the same fetch reaches it.

    tests/sessions/check-local-network.py --base DIR --httpget PATH [--helper PATH] [--dylib PATH] [--work DIR]
"""
import argparse, http.server, importlib.util, json, os, signal, subprocess, sys, tempfile, threading
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import sources


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--base", type=Path, required=True, help="a prepared n72 base (its PAC routes private addresses DIRECT)")
    ap.add_argument("--httpget", type=Path, required=True, help="contrib/it-proxy/httpget built for armv6")
    ap.add_argument("--itpack", type=Path, default=sources.path("qemu-ios") / "build/guest-package/armv6.itpack")
    ap.add_argument("--internet", default="http://example.com/")
    ap.add_argument("--helper")
    ap.add_argument("--firmwarekit", default=os.environ.get("LTM_FIRMWAREKIT"),
                    help="stopped-storage admission worker (default: firmwarekit beside the helper)")
    ap.add_argument("--dylib", default=os.environ.get("LTM_QEMU_DYLIB", str(sources.qemu_build() / "libqemu-arm.dylib")))
    ap.add_argument("--files", type=Path, default=Path.home() / "Developer/qemu-ios-files")
    ap.add_argument("--usbmuxd", default=str(sources.path("usbmuxd") / "src/usbmuxd"))
    ap.add_argument("--frameworks")
    ap.add_argument("--work", type=Path)
    args = ap.parse_args()

    lan_ip = next((ip for ip in (subprocess.run(["ipconfig", "getifaddr", i], capture_output=True, text=True).stdout.strip()
                                 for i in ("en0", "en1")) if ip), None)
    if not lan_ip:
        print("SKIP: this Mac has no en0/en1 address to stand in for a LAN host")
        return 0
    hits = []

    class Probe(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            hits.append(self.path)
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"lan probe")

        def log_message(self, *a):
            pass

    server = http.server.ThreadingHTTPServer((lan_ip, 0), Probe)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    lan_url = f"http://{lan_ip}:{server.server_address[1]}/lan-probe"

    spec = importlib.util.spec_from_file_location("check_sessions", ROOT / "tests/sessions/check-sessions.py")
    sessions = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(sessions)
    work = args.work or Path(tempfile.mkdtemp(prefix="ltm-local-network-"))
    work.mkdir(parents=True, exist_ok=True)
    print(f"work: {work}", flush=True)
    helper = sessions.build(args, work)
    cfg = {"helper": str(helper), "requirement": sessions.helper_requirement(args), "firmwarekit": args.firmwarekit, "usbmuxd": args.usbmuxd, "ipa": "", "bundleID": "",
           "work": str(work), "files": str(args.files), "ipodNAND": "", "ipadBase": "", "timeout": 600,
           "proxy": {"board": "ipod", "base": str(args.base), "itpack": str(args.itpack), "httpget": str(args.httpget),
                     "url": "", "lan": lan_url, "internet": args.internet}}
    if args.frameworks:
        cfg["frameworks"] = args.frameworks
    (work / "config.json").write_text(json.dumps(cfg, indent=1))
    driver = subprocess.Popen([work / "session-driver", work / "config.json"], stdout=open(work / "driver.jsonl", "w"),
                              stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=dict(os.environ, LTM_QEMU_DYLIB=args.dylib))
    events = []
    try:
        try:
            driver.wait(timeout=620)
        except subprocess.TimeoutExpired:
            driver.kill()
            driver.wait()
    finally:
        server.shutdown()
        for line in (work / "driver.jsonl").read_text(errors="replace").splitlines():
            try:
                events.append(json.loads(line))
            except ValueError:
                pass
        for pid in {e["pid"] for e in events if e.get("event") in ("hello", "booted", "usbmuxd") and e.get("pid")}:
            try:
                os.kill(pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass

    def got(label):
        return next((e for e in events if e.get("event") == "get" and e.get("label") == label), {}).get("output", "")

    results = []

    def check(ok, what):
        results.append(bool(ok))
        print(f"  {'ok ' if ok else 'FAIL'} {what}", flush=True)

    off, on = got("lan-off"), got("lan-on")
    check(got("internet").startswith("HTTP 200"), f"internet through the proxy: {got('internet')[:60]!r}")
    # Off: httpget fails and nothing reaches the listener; on: one request, the one after the flip.
    check(off.startswith("ERROR"), f"LAN refused while off: {off[:60]!r}")
    check(on.startswith("HTTP 200") and hits == ["/lan-probe"], f"LAN reached once turned on: {on[:60]!r}, listener saw {hits}")
    check(any(e.get("event") == "done" for e in events) and driver.returncode == 0, f"driver finished (exit {driver.returncode})")
    print(f"\n{sum(results)}/{len(results)} passed; events {work}/driver.jsonl")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
