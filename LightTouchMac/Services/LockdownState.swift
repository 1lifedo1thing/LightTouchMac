import Foundation

extension DeviceServices {
    /// lockdownd's ActivationState: "Activated", "Unactivated", "FactoryActivated".
    ///
    /// The tell for a torn filesystem. A hard exit loses HFS+ catalog updates
    /// that were still in memory, and if the activation record is among them the
    /// guest boots to the Connect-to-iTunes screen — where lockdownd still
    /// answers but every service refuses, so the app's only symptom was an
    /// unexplained "Install service error (connect): code -256". Asking turns
    /// that dead end into something the UI can name and offer a fix for.
    func activationState() async -> String? { try? await lockdownValue("ActivationState") }

    /// Stock lockdown reads share the same endpoint, timeout and error contract.
    func lockdownValue(_ key: String) async throws -> String? {
        if !local {
            guard case .string(let state) = try await remote(.lockdownValue(key), seconds: Timeouts.query) else { return nil }
            return state
        }
        #if LIGHTTOUCH_SERVICES
        return try await run(Timeouts.query, "lockdown " + key) { device in
            var client: OpaquePointer?
            let rc = lockdownd_client_new_with_handshake(device, &client, "LightTouchMac")
            guard rc.ok, let client else { throw DeviceError.lockdown(rc.code) }
            defer { _ = lockdownd_client_free(client) }

            var value: plist_t?
            let vr = lockdownd_get_value(client, nil, key, &value)
            guard vr.ok, let value else { throw DeviceError.lockdown(vr.code) }
            defer { plist_free(value) }
            return IMobileDevice.decode(value) as? String
        }
        #else
        throw Self.unrouted
        #endif
    }

}
