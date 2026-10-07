import Foundation

/// About Light Touch's credits: the bundled components with their versions (build-inputs.json `components`, written
/// by scripts/vendor; a development build has none) and the licences (Help.txt's Licenses section, with a link to
/// Resources/licenses). The app styles the runs (AboutPanel).
public enum AboutCredits {
    public struct Run: Equatable {
        public var text: String
        public var isHeading = false
        public var link: URL?
    }

    public static func runs(buildInputs: Data?, help: String?, licenses: URL?) -> [Run] {
        var out: [Run] = []
        let components = buildInputs.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["components"] as? [String: String] ?? [:]
        if !components.isEmpty {
            let first = ["qemu-ios", "usbmuxd", "guest tools"]
            let names = first.filter { components[$0] != nil }
                + components.keys.filter { !first.contains($0) }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            out.append(Run(text: "Components\n", isHeading: true))
            out.append(Run(text: names.map { "\($0) \(components[$0]!)" }.joined(separator: "\n") + "\n\n"))
        }
        if let help, let start = help.range(of: "# Licenses\n") {
            let section = help[start.upperBound...]
            let paragraph = section[..<(section.range(of: "\n#")?.lowerBound ?? section.endIndex)]
            out.append(Run(text: "Licenses\n", isHeading: true))
            out.append(Run(text: paragraph.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"))
        }
        if let licenses, FileManager.default.fileExists(atPath: licenses.path) {
            out.append(Run(text: "Show the license files", link: licenses))
        }
        return out
    }
}
