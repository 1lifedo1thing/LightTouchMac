#!/usr/bin/env python3
"""Link the production IMobileDevice service connection against a native service-connection fixture (a
libimobiledevice of its own with the same symbols): each step's exact error, the native call order and cleanup."""
from pathlib import Path
import subprocess
import sys
import tempfile
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import host_service

root = Path(__file__).resolve().parents[2]
c_source = r'''
#include <assert.h>
#include <stdint.h>
#include <string.h>
static int stage, error, missing;
static int lockdown, descriptor, client;
static char calls[32];
static unsigned count;
static void record(char c) { assert(count < 31); calls[count++] = c; calls[count] = 0; }
void fixture_reset(int s, int e, int m) { stage=s; error=e; missing=m; count=0; calls[0]=0; }
const char *fixture_calls(void) { return calls; }
int lockdownd_client_new_with_handshake(void *device, void **output, const char *label) {
    assert(device == (void *)17 && strcmp(label, "LightTouchMac") == 0);
    record('H'); *output = missing & 1 ? 0 : &lockdown; return stage == 1 ? error : 0;
}
int lockdownd_start_service(void *connection, const char *name, void **output) {
    assert(connection == &lockdown && strcmp(name, "com.apple.mobile.installation_proxy") == 0);
    record('S'); *output = missing & 2 ? 0 : &descriptor; return stage == 2 ? error : 0;
}
int lockdownd_client_free(void *connection) { assert(connection == &lockdown); record('L'); return 0; }
int lockdownd_service_descriptor_free(void *service) { assert(service == &descriptor); record('D'); return 0; }
int instproxy_client_new(void *device, void *service, void **output) {
    assert(device == (void *)17 && service == &descriptor);
    assert(strcmp(calls, "HSL") == 0); /* lockdown must close before this socket opens */
    record('N'); *output = missing & 4 ? 0 : &client; return stage == 3 ? error : 0;
}
int instproxy_client_free(void *connection) { assert(connection == &client); record('C'); return 0; }
/* The rest of what IMobileDevice.swift links; not reached here. */
int idevice_new(void **device, const char *udid) { return -1; }
int idevice_free(void *device) { return 0; }
int plist_to_xml(void *node, char **xml, unsigned *length) { return -1; }
void plist_mem_free(void *ptr) {}
int plist_from_xml(const char *xml, unsigned length, void **node) { return -1; }
'''
swift_source = r'''
import Foundation
nonisolated enum HostServiceResources {
    static let udid: String? = nil
}
nonisolated struct InstproxyError: Equatable { let code: Int32 }
nonisolated enum DeviceError: Error, Equatable {
    case unavailable, notAttached, lockdown(Int32), instproxy(InstproxyError, phase: String?)
}
@main struct Check {
    static func main() throws {
        let library = dlopen(nil, RTLD_NOW)
        typealias Reset = @convention(c) (Int32, Int32, Int32) -> Void
        typealias Calls = @convention(c) () -> UnsafePointer<CChar>
        let reset = unsafeBitCast(dlsym(library, "fixture_reset")!, to: Reset.self)
        let calls = unsafeBitCast(dlsym(library, "fixture_calls")!, to: Calls.self)
        let device = OpaquePointer(bitPattern: 17)!
        func failure(_ stage: Int32, _ code: Int32, _ missing: Int32,
                     expected: DeviceError, trace: String) throws {
            reset(stage, code, missing)
            do {
                _ = try IMobileDevice.startInstallationProxy(device: device)
                preconditionFailure("unexpected successful connection")
            } catch let error as DeviceError {
                precondition(error == expected, "wrong error: \(error), expected \(expected)")
            }
            precondition(String(cString: calls()) == trace, "wrong cleanup: \(String(cString: calls()))")
        }
        // Device locked, prohibited service, and transport failures retain
        // their exact lockdown code rather than turning into instproxy -256.
        for code: Int32 in [-17, -21, -7, -256] {
            try failure(1, code, 1, expected: .lockdown(code), trace: "H")
            try failure(1, code, 0, expected: .lockdown(code), trace: "HL")
            try failure(2, code, 2, expected: .lockdown(code), trace: "HSL")
            try failure(2, code, 0, expected: .lockdown(code), trace: "HSLD")
        }
        for code: Int32 in [-3, -4, -5, -256] {
            try failure(3, code, 4, expected: .instproxy(.init(code: code), phase: "connect"), trace: "HSLND")
            try failure(3, code, 0, expected: .instproxy(.init(code: code), phase: "connect"), trace: "HSLNCD")
        }
        // Defensive handling of broken native success-with-null outputs.
        try failure(0, 0, 1, expected: .lockdown(-256), trace: "H")
        try failure(0, 0, 2, expected: .lockdown(-256), trace: "HSL")
        try failure(0, 0, 4, expected: .instproxy(.init(code: -256), phase: "connect"), trace: "HSLND")
        reset(0, 0, 0)
        let client = try IMobileDevice.startInstallationProxy(device: device)
        precondition(String(cString: calls()) == "HSLND", "helper freed the caller's client")
        _ = instproxy_client_free(client)
        precondition(String(cString: calls()) == "HSLNDC")
        print("PASS: exact lockdown/instproxy errors, native call order, partial/null handles, descriptor cleanup, caller-owned success")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="ltm-instproxy-connect-") as directory:
    temp = Path(directory)
    (temp / "fixture.c").write_text(c_source)
    (temp / "check.swift").write_text(swift_source)
    subprocess.run(["xcrun", "clang", "-dynamiclib", "-Wall", "-Werror", "-install_name", "@rpath/libimobiledevice-1.0.dylib",
                    str(temp / "fixture.c"), "-o", str(temp / "libimobiledevice-1.0.dylib")], check=True)
    binary = temp / "check"
    # The services helper's build: its bridging header (the real C API), LIGHTTOUCH_SERVICES, Swift 5 and default
    # MainActor isolation; linked to the fixture in place of libimobiledevice.
    headers = [x for f in host_service.imobiledevice_flags() if f.startswith("-I") for x in ("-Xcc", f)]
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-D", "LIGHTTOUCH_SERVICES",
                    "-default-isolation", "MainActor", "-module-cache-path", str(temp / "modules"), *headers,
                    "-import-objc-header", str(root / "LightTouchServices/Lockdown/Lockdown.h"),
                    str(root / "LightTouchMac/Transport/IMobileDevice.swift"), str(temp / "check.swift"),
                    "-L", str(temp), "-limobiledevice-1.0", "-Xlinker", "-rpath", "-Xlinker", str(temp),
                    "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=10)
