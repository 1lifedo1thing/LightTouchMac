import Foundation
import HostRuntime

/// tests/fixtures/machines.json (`LightTouchDevice --machines`) as the process's machines (Machines), for checks that
/// run no helper. Evaluate it before the first board lookup.
let fixtureMachines: Void = {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("machines.json")
    Machines.set(try! JSONDecoder().decode([DeviceInfo].self, from: Data(contentsOf: url)))
}()
