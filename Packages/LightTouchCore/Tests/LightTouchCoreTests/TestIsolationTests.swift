import Foundation
import Testing
import TestIsolation
@testable import LightTouchCore

/// No test may touch the real library: the process runs in a private home (Tests/TestIsolation).
struct TestIsolationTests {
    @Test func appStateLogsAndCachesAreOutsideTheRealHome() {
        let home = String(cString: ltm_test_home())
        let real = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? "/Users"
        #expect(!home.isEmpty && !home.hasPrefix(real + "/Library"))
        for url in [Bundled.stateDirectory, Bundled.logsDirectory,
                    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0],
                    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]] {
            #expect(!url.path.hasPrefix(real + "/Library"), "\(url.path) is the real library")
        }
    }
}
