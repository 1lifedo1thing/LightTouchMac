// Device ▸ Debugging ▸ Debug Port…: the emulator's GDB remote stub, as a sheet: its switch, where it is, what it
// is, and the commands that attach to it, each with a Copy button.

import LightTouchCore
import SwiftUI

struct DebugPortView: View {
    let shortName: String
    /// The port this boot listens on; nil when it started without one.
    let port: Int?
    /// lldb with the kernel's symbols and XNU macros (EmulatorController.lldbAttachCommand), while there is a port.
    let lldbWithSymbols: String?
    @State var enabled: Bool
    var onToggle: () -> Void
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // FIXME: ugly.
            Toggle(
                isOn: Binding(
                    get: { enabled },
                    set: {
                        enabled = $0
                        onToggle()
                    }
                )
            ) {
                Text("Debug Port").font(.headline)
            }
            .toggleStyle(.switch)

            Text(DebugPortText.state(shortName: shortName, enabled: enabled, port: port))
                .foregroundStyle(.secondary)

            Text(
                "The emulator’s GDB remote stub. A debugger attached to it runs the \(shortName)’s CPU: it pauses the whole device and reads or changes its kernel and apps. Only this Mac can reach it, and it has no password."
            )
            .fixedSize(horizontal: false, vertical: true)

            if let port {
                // FIXME: ugly. `id: \.0` ?? jesus christ
                ForEach(DebugPortText.commands(port: port, lldbWithSymbols: lldbWithSymbols), id: \.0) {
                    title,
                    command in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        HStack(alignment: .top) {
                            Text(command)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)

                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(command, forType: .string)
                            }
                        }
                    }
                }
                if lldbWithSymbols != nil {
                    Text("Replace KERNELCACHE with the decrypted kernel and QEMU_IOS with a qemu-ios checkout.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

// TODO: Add preview
