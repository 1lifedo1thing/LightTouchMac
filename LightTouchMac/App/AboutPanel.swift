import LightTouchCore
import Cocoa

/// About Light Touch: the standard panel with AboutCredits' runs as its credits.
extension AboutCredits {
    @MainActor static func show() {
        let bundle = Bundle.main
        let text = credits(buildInputs: bundle.url(forResource: "build-inputs", withExtension: "json").flatMap { try? Data(contentsOf: $0) },
                           help: bundle.url(forResource: "Help", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) },
                           licenses: bundle.resourceURL?.appendingPathComponent("licenses", isDirectory: true))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: text])
    }

    static func credits(buildInputs: Data?, help: String?, licenses: URL?) -> NSAttributedString {
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                                                   .foregroundColor: NSColor.labelColor]
        let heading = body.merging([.font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)]) { $1 }
        let out = NSMutableAttributedString()
        for run in runs(buildInputs: buildInputs, help: help, licenses: licenses) {
            var attributes = run.isHeading ? heading : body
            if let link = run.link { attributes[.link] = link }
            out.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return out
    }
}
