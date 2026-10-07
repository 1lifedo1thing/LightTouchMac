#!/usr/bin/env python3
"""Attach to Local Network, off by default: the guest reaches the internet but not the Mac's LAN until it is turned on.

One iPod boots as the app does (the session driver's proxy.swift with `lan`): the helper's web proxy on the wifi
guestfwd and slirp's lan=off. A listener on this Mac's LAN address stands in for a LAN host. The guest's httpget
(CFNetwork; the image's PAC sends private addresses DIRECT, so slirp carries it) fetches a public page (through
the proxy) and the listener; the listener must see nothing. Then `.netLocalNetwork(true)` (qemu_ios_ui_net_lan,
in place) and the same fetch reaches it.

Sockets observed: a DYLD_INSERT_LIBRARIES shim in the driver (the app's side), usbmuxd, LightTouchServices and the
helper (a copy signed without the hardened runtime) logs every connect/sendto destination. While off, none may be a
private, link-local or multicast address or one of this Mac's DNS servers: any of those makes macOS ask for Local
Network access. The guest's own DNS (a plain host name, DIRECT, completed by the netdev's domainname) must still
resolve while off: slirp hands it to the emulator's loopback resolver, which asks the system resolver.

    tests/sessions/check-local-network.py --base DIR --httpget PATH [--helper PATH] [--dylib PATH] [--work DIR]
"""
import argparse, http.server, importlib.util, ipaddress, json, os, re, shutil, signal, subprocess, sys, tempfile, threading
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import sources

SOCKET_LOG = r"""
#include <arpa/inet.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#define INTERPOSE(n, o) __attribute__((used)) static struct { const void *a, *b; } i_##o \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)n, (const void *)o };
static void note(const char *kind, const struct sockaddr *a) {
    char host[INET6_ADDRSTRLEN] = "", line[200]; int port; struct timeval tv; const char *path = getenv("LTM_SOCKET_LOG");
    if (!a || !path) return;
    if (a->sa_family == AF_INET) { const struct sockaddr_in *s = (const void *)a; inet_ntop(AF_INET, &s->sin_addr, host, sizeof host); port = ntohs(s->sin_port); }
    else if (a->sa_family == AF_INET6) { const struct sockaddr_in6 *s = (const void *)a; inet_ntop(AF_INET6, &s->sin6_addr, host, sizeof host); port = ntohs(s->sin6_port); }
    else return;
    gettimeofday(&tv, NULL);
    int fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd < 0) return;
    write(fd, line, snprintf(line, sizeof line, "%ld.%06d %s %s %s %d\n", (long)tv.tv_sec, (int)tv.tv_usec, getprogname(), kind, host, port));
    close(fd);
}
static int c(int fd, const struct sockaddr *a, socklen_t l) { note("connect", a); return connect(fd, a, l); }
static ssize_t st(int fd, const void *b, size_t n, int f, const struct sockaddr *a, socklen_t l) { note("sendto", a); return sendto(fd, b, n, f, a, l); }
static ssize_t sm(int fd, const struct msghdr *m, int f) { note("sendmsg", m ? m->msg_name : NULL); return sendmsg(fd, m, f); }
static int cx(int fd, const sa_endpoints_t *e, sae_associd_t as, unsigned int fl, const struct iovec *v, unsigned int vc, size_t *len, sae_connid_t *id)
    { note("connectx", e ? e->sae_dstaddr : NULL); return connectx(fd, e, as, fl, v, vc, len, id); }
INTERPOSE(c, connect) INTERPOSE(st, sendto) INTERPOSE(sm, sendmsg) INTERPOSE(cx, connectx)
"""


def observed(helper, work):
    """The socket shim (every architecture a child may be: system tools are arm64e) and a helper copy it can load into."""
    (work / "socket-log.c").write_text(SOCKET_LOG)
    shim = work / "socket-log.dylib"
    subprocess.run(["clang", "-dynamiclib", "-arch", "arm64", "-arch", "arm64e", "-arch", "x86_64", "-o", shim, work / "socket-log.c"], check=True)
    copy = helper.with_name(helper.name + "-observed")
    shutil.copy2(helper, copy)
    entitlements = work / "helper.entitlements"
    entitlements.write_bytes(subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", helper], capture_output=True, check=True).stdout)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", entitlements, copy], check=True, capture_output=True)
    return shim, copy


def local_network(host, dns_servers):
    """A destination macOS counts as the local network: private, link-local, multicast, or this Mac's DNS server."""
    a = ipaddress.ip_address(host.split("%")[0])
    a = getattr(a, "ipv4_mapped", None) or a
    return not a.is_loopback and (a.is_private or a.is_link_local or a.is_multicast or str(a) == "255.255.255.255"
                                  or host in dns_servers)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--base", type=Path, required=True, help="a prepared n72 base (its PAC routes private addresses DIRECT)")
    ap.add_argument("--httpget", type=Path, required=True, help="contrib/it-proxy/httpget built for armv6")
    ap.add_argument("--itpack", type=Path, default=sources.path("qemu-ios") / "build/guest-package/armv6.itpack")
    ap.add_argument("--internet", default="http://example.com/")
    ap.add_argument("--dns", default="http://example/", help="a plain host name's page (DIRECT), completed by --domain")
    ap.add_argument("--domain", default="com")
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
    shim, helper = observed(Path(sessions.build(args, work)), work)
    dns_servers = set(re.findall(r"nameserver\[\d+\] : (\S+)", subprocess.run(["scutil", "--dns"], capture_output=True, text=True).stdout))
    cfg = {"helper": str(helper), "requirement": None, "firmwarekit": args.firmwarekit, "usbmuxd": args.usbmuxd, "ipa": "", "bundleID": "",
           "work": str(work), "files": str(args.files), "ipodNAND": "", "ipadBase": "", "timeout": 600,
           "proxy": {"board": "ipod", "base": str(args.base), "itpack": str(args.itpack), "httpget": str(args.httpget),
                     "url": "", "lan": lan_url, "internet": args.internet,
                     "dns": args.dns, "domain": args.domain}}
    if args.frameworks:
        cfg["frameworks"] = args.frameworks
    (work / "config.json").write_text(json.dumps(cfg, indent=1))
    driver = subprocess.Popen([work / "session-driver", work / "config.json"], stdout=open(work / "driver.jsonl", "w"),
                              stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=dict(os.environ, LTM_QEMU_DYLIB=args.dylib,
                                       DYLD_INSERT_LIBRARIES=str(shim), LTM_SOCKET_LOG=str(work / "sockets.log")))
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
    dns = got("dns")
    check(dns.startswith("HTTP "), f"the guest's own DNS while off ({args.dns} DIRECT): {dns[:60]!r}")
    sockets = [l.split() for l in (work / "sockets.log").read_text().splitlines()] if (work / "sockets.log").exists() else []
    flip = next((e["at"] for e in events if e.get("event") == "lan-on"), None)
    check(flip and any(s[1].startswith("LightTouchDevice") for s in sockets), f"helper sockets observed ({len(sockets)} in {work}/sockets.log)")
    leaks = sorted({" ".join(s[1:]) for s in sockets if flip and float(s[0]) < flip and local_network(s[3], dns_servers)})
    check(not leaks, f"nothing sent to the local network while off: {leaks or 'none'}")
    lan_host, lan_port = lan_ip, str(server.server_address[1])
    check(any(flip and float(s[0]) >= flip and s[3] == lan_host and s[4] == lan_port for s in sockets),
          "the helper connected to the LAN listener once turned on")
    check(any(e.get("event") == "done" for e in events) and driver.returncode == 0, f"driver finished (exit {driver.returncode})")
    print(f"\n{sum(results)}/{len(results)} passed; events {work}/driver.jsonl")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
