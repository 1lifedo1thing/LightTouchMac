import Cocoa

/// About Light Touch: the standard panel, its credits the bundled components with their versions (build-inputs.json
/// `components`, written by scripts/build-release.py; a development build has none) and the licences (Help.txt's
/// Licenses section, with a link to Resources/licenses).
enum AboutCredits {
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
        let components = buildInputs.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["components"] as? [String: String] ?? [:]
        if !components.isEmpty {
            let first = ["qemu-ios", "usbmuxd", "guest tools"]
            let names = first.filter { components[$0] != nil }
                + components.keys.filter { !first.contains($0) }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            out.append(NSAttributedString(string: "Components\n", attributes: heading))
            out.append(NSAttributedString(string: names.map { "\($0) \(components[$0]!)" }.joined(separator: "\n") + "\n\n", attributes: body))
        }
        if let help, let start = help.range(of: "# Licenses\n") {
            let section = help[start.upperBound...]
            let paragraph = section[..<(section.range(of: "\n#")?.lowerBound ?? section.endIndex)]
            out.append(NSAttributedString(string: "Licenses\n", attributes: heading))
            out.append(NSAttributedString(string: paragraph.trimmingCharacters(in: .whitespacesAndNewlines) + "\n", attributes: body))
        }
        if let licenses, FileManager.default.fileExists(atPath: licenses.path) {
            out.append(NSAttributedString(string: "Show the license files", attributes: body.merging([.link: licenses]) { $1 }))
        }
        return out
    }
}
