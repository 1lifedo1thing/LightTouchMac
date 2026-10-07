import Foundation

/// A user-initiated ProcessInfo activity, held while `held` is true: a download, preparation, install,
/// recording or file transfer keeps the Mac from idle sleep (and the app out of App Nap) until it ends.
struct UserActivity {
    let reason: String
    private var token: NSObjectProtocol?

    init(_ reason: String) { self.reason = reason }

    var held: Bool {
        get { token != nil }
        set {
            guard newValue != held else { return }
            if newValue { token = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: reason) }
            else if let token { ProcessInfo.processInfo.endActivity(token); self.token = nil }
        }
    }
}
