// The device's icon in the sidebar and the Add Device sheet: macOS's own artwork for the model (Finder's),
// found by its product type through AppleDeviceType; an SF Symbol where this macOS doesn't declare the model.
// Text keeps the app's names (marketingName): macOS calls both iPods just "iPod touch".

import AppKit
import HostRuntime

extension Board {
    /// macOS's declared type for the board: its product type is the com.apple.device-model-code tag.
    var deviceType: AppleDeviceType? { AppleDeviceType(productType) }

    var icon: NSImage {
        Self.icon(
            modelCode: productType,
            fallbackSymbol: [.iPad: "ipad", .iPhone: "iphone"][facts.kind] ?? "ipodtouch"
        )
    }

    static func icon(modelCode: String, fallbackSymbol: String) -> NSImage {
        AppleDeviceType(modelCode)?.icon ?? NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: nil)!
    }
}
