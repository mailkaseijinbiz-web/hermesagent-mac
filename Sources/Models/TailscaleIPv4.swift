import Foundation

/// Best-effort Tailscale IPv4 lookup for settings display (non-blocking).
enum TailscaleIPv4 {
    private static let candidatePaths = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
    ]

  /// Returns a dotted IPv4 string, or nil when Tailscale is unavailable.
  /// Prefers `tailscale ip -4`; falls back to scanning utun* interfaces via getifaddrs
  /// (reliable at launch when the CLI subprocess is slow or PATH differs from the GUI app).
  static func lookup() -> String? {
    if let cli = lookupViaCLI(), isTailscaleIPv4(cli) { return cli }
    return lookupViaInterfaces()
  }

  /// Tailscale CGNAT 100.64.0.0/10 — rejects CLI error text that happens to contain a dot.
  static func isTailscaleIPv4(_ s: String) -> Bool {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    let octets = trimmed.split(separator: ".").compactMap { Int($0) }
    guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
    return octets[0] == 100 && (64...127).contains(octets[1])
  }

  private static func lookupViaCLI() -> String? {
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
      // `tailscale ip -4` may emit multiple lines; bind to the first routable address.
      let first = out.split(whereSeparator: \.isNewline).first.map(String.init) ?? out
      guard isTailscaleIPv4(first) else { return nil }
      return first.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
      return nil
    }
  }

  /// Scan network interfaces for a Tailscale CGNAT address (100.64.0.0/10).
  private static func lookupViaInterfaces() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }
    var ptr: UnsafeMutablePointer<ifaddrs>? = first
    while let p = ptr {
      defer { ptr = p.pointee.ifa_next }
      let iface = p.pointee
      guard iface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
      var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      getnameinfo(iface.ifa_addr, socklen_t(iface.ifa_addr.pointee.sa_len),
                  &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
      let ip = String(cString: hostname)
      let octets = ip.split(separator: ".").compactMap { Int($0) }
      if octets.count == 4, octets[0] == 100, (64...127).contains(octets[1]) {
        return ip
      }
    }
    return nil
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
