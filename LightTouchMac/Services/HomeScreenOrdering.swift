import HostServiceClient
import HostServiceWire
import HostRuntime
import Foundation

extension DeviceServices {
    @discardableResult
    func moveOnHomeScreen(_ bundleID: String, before other: String?, profile: Board) async throws -> [String] {
        try await moveOnHomeScreen(bundleID, before: other, deviceName: profile.shortName)
    }
}
