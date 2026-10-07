// What the views here reach into and the fixture leaves out: the device hub, as the Carrier panel's window
// controller names it (the panel itself talks only to CarrierBackend).
import LightTouchCore
import HostRuntime

final class EmulatorController {
    struct Instance { let name = "iPhone" }
    let instance = Instance()
    var carrierSettings = CarrierSettings()
    func setCarrierSettings(_ settings: CarrierSettings) -> Bool { true }
    func modem(_ property: String, _ value: String, done: @escaping @MainActor (Bool) -> Void) {}
    func modemStatus(_ done: @escaping @MainActor (ModemStatus?) -> Void) {}
}
