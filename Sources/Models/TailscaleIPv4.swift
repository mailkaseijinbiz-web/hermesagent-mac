import Foundation

/// Best-effort Tailscale IPv4 lookup for settings display (non-blocking).
enum TailscaleIPv4 {
    private static let candidatePaths = [
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ]

  /// Returns a dotted IPv4 string, or nil when Tailscale is unavailable.
  static func lookup() -> String? {
    guard let path = resolveBinary() else { return nil }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = ["ip", "-4"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do {
      try proc.run()
      proc.waitUntilExit()
      guard proc.terminationStatus == 0 else { return nil }
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let out = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !out.isEmpty, out.contains(".") else { return nil }
      return out
    } catch {
      return nil
    }
  }

  private static func resolveBinary() -> String? {
    for p in candidatePaths where FileManager.default.isExecutableFile(atPath: p) { return p }
    let which = Process()
    which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    which.arguments = ["tailscale"]
    let pipe = Pipe()
    which.standardOutput = pipe
    which.standardError = FileHandle.nullDevice
    guard (try? which.run()) != nil else { return nil }
    which.waitUntilExit()
    guard which.terminationStatus == 0 else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let path = String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return path.isEmpty ? nil : path
  }
}
