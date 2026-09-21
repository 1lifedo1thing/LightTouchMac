#!/usr/bin/env python3
"""Production snapshot command and parser: binary files, quoting, malformed input."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
fixture = r'''import Foundation
@main struct Check {
 static func main() throws {
  let directory = URL(fileURLWithPath: CommandLine.arguments[1])
  let first = directory.appendingPathComponent("file ' one").path
  let second = directory.appendingPathComponent("missing").path
  let third = directory.appendingPathComponent("three").path
  let binary = Data([0, 10, 255, 32, 49, 10])
  try binary.write(to: URL(fileURLWithPath: first))
  try Data("plist".utf8).write(to: URL(fileURLWithPath: third))
  let paths = [first, second, third]
  let request = GuestFileSnapshot(paths: paths)
  let process = Process(), pipe = Pipe()
  process.executableURL = URL(fileURLWithPath: "/bin/sh")
  process.arguments = ["-c", request.command]
  process.standardOutput = pipe
  try process.run()
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit(); precondition(process.terminationStatus == 0)
  let files = try request.decode(data)
  precondition(files[first] == binary && files[second] == Data() && files[third] == Data("plist".utf8))
  for bad in [Data("-1\n".utf8), Data("999999999999999999999999999\n".utf8), Data("4\nabc".utf8), Data("0\ntrailing".utf8), Data("words\n".utf8), Data(data.dropLast()), data + Data([1])] {
   do { _ = try request.decode(bad); fatalError("Accepted corrupt file") }
   catch {}
  }
  print("PASS: one guest command preserves binary files, spaces/quotes, missing files; corrupt framing rejected")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-guest-snapshot-') as directory:
    work=Path(directory); (work/'check.swift').write_text(fixture)
    subprocess.run(['swiftc','-module-cache-path',str(work/'modules'),str(root/'LightTouchMac/GuestFileSnapshot.swift'),str(work/'check.swift'),'-o',str(work/'check')],check=True)
    subprocess.run([str(work/'check'),str(work)],check=True)
