// Settings ▸ General ▸ 120 Hz refresh: a device started with it on runs its panel's frame interrupt, which iOS's
// compositor draws on, at 120 Hz instead of the hardware's 60 (Board.refreshGlobals). Experimental: apps that count
// frames rather than time run fast.

import Foundation

enum DisplayRefresh {
    /// UserDefaults key for the toggle (off unless turned on).
    static let key = "ExperimentalRefresh120"
    /// The refresh the next device start gets.
    static var hz: Int { UserDefaults.standard.bool(forKey: key) ? 120 : 60 }
}
