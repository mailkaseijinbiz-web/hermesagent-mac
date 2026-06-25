import Foundation

@MainActor
class HermesCLI {
    static let shared = HermesCLI()
    
    let hermesPath = "/Users/keitayasui/.local/bin/hermes"
    let envPath = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".hermes/.env")
    
    // Merged environment variables from shell and .env
    var mergedEnvironment: [String: String] = [:]
    
    // Dashboard process handle
    private var dashboardProcess: Process? = nil
    
    private init() {
        self.mergedEnvironment = getShellEnvironment()
        loadHermesEnv()
        // Wide terminal so rich-table CLI output (skills list, etc.) isn't truncated.
        self.mergedEnvironment["COLUMNS"] = "300"
    }
    
    // Sync environment variables from the user's login shell (zsh)
    private func getShellEnvironment() -> [String: String] {
        var env: [String: String] = ProcessInfo.processInfo.environment
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "env"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let lines = output.components(separatedBy: .newlines)
                for line in lines {
                    let parts = line.split(separator: "=", maxSplits: 1)
                    if parts.count == 2 {
                        let key = String(parts[0])
                        let val = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                        env[key] = val
                    }
                }
            }
        } catch {
            print("Failed to load shell environment: \(error)")
        }
        
        return env
    }
    
    // Parse the ~/.hermes/.env file
    private func loadHermesEnv() {
        guard FileManager.default.fileExists(atPath: envPath.path) else { return }
        do {
            let content = try String(contentsOf: envPath, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                let parts = trimmed.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    let key = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let val = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                    mergedEnvironment[key] = val
                }
            }
        } catch {
            print("Failed to read ~/.hermes/.env: \(error)")
        }
    }
    
    // Get macOS Local IP Address (Wi-Fi en0 primarily)
    func getLocalIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next }
                guard let interface = ptr?.pointee else { continue }
                
                let addrFamily = interface.ifa_addr.pointee.sa_family
                if addrFamily == UInt8(AF_INET) { // IPv4
                    let name = String(cString: interface.ifa_name)
                    if name == "en0" || name == "en1" || name == "ap0" { // Wi-Fi interfaces
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                    &hostname, socklen_t(hostname.count),
                                    nil, socklen_t(0), NI_NUMERICHOST)
                        address = String(cString: hostname)
                        break
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        
        // Fallback: search other interfaces if en0 was not found (e.g. ethernet)
        if address == nil {
            if getifaddrs(&ifaddr) == 0 {
                var ptr = ifaddr
                while ptr != nil {
                    defer { ptr = ptr?.pointee.ifa_next }
                    guard let interface = ptr?.pointee else { continue }
                    let addrFamily = interface.ifa_addr.pointee.sa_family
                    if addrFamily == UInt8(AF_INET) {
                        let name = String(cString: interface.ifa_name)
                        if name != "lo0" {
                            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                            getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                        &hostname, socklen_t(hostname.count),
                                        nil, socklen_t(0), NI_NUMERICHOST)
                            address = String(cString: hostname)
                            break
                        }
                    }
                }
                freeifaddrs(ifaddr)
            }
        }
        
        return address
    }
    
    // Get Tailscale IP address (100.64.0.0/10 CGNAT range, on a utun interface).
    // Preferred for mobile connectivity since it's reachable from anywhere on the tailnet.
    func getTailscaleIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next }
                guard let interface = ptr?.pointee else { continue }

                let addrFamily = interface.ifa_addr.pointee.sa_family
                if addrFamily == UInt8(AF_INET) { // IPv4
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, socklen_t(0), NI_NUMERICHOST)
                    let ip = String(cString: hostname)

                    // Tailscale CGNAT range: 100.64.0.0 – 100.127.255.255
                    let octets = ip.split(separator: ".").compactMap { Int($0) }
                    if octets.count == 4, octets[0] == 100, octets[1] >= 64, octets[1] <= 127 {
                        address = ip
                        break
                    }
                }
            }
            freeifaddrs(ifaddr)
        }

        return address
    }

    // Tailscale MagicDNS hostname (e.g. keitamac-mini.tailfc8906.ts.net). Stable across
    // IP changes, so clients/QR can use it instead of a raw IP the user must manage.
    func getTailscaleHostname() -> String? {
        let candidates = [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"
        ]
        guard let bin = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["status", "--json"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let selfNode = json["Self"] as? [String: Any],
              let dns = (selfNode["DNSName"] as? String), !dns.isEmpty else { return nil }
        return dns.hasSuffix(".") ? String(dns.dropLast()) : dns
    }

    // Start dashboard bound to all interfaces
    func startDashboard(port: Int) async -> Bool {
        // Stop any running dashboard first
        _ = await exec(args: ["dashboard", "--stop"])
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: hermesPath)
        process.arguments = ["dashboard", "--host", "0.0.0.0", "--insecure", "--no-open", "--port", String(port)]
        process.environment = mergedEnvironment
        
        do {
            try process.run()
            self.dashboardProcess = process
            // Wait slightly to ensure it bounds successfully
            try await Task.sleep(nanoseconds: 500_000_000)
            return process.isRunning
        } catch {
            print("Failed to start dashboard: \(error)")
            return false
        }
    }
    
    // Stop dashboard
    func stopDashboard() async {
        if let proc = dashboardProcess {
            proc.terminate()
            dashboardProcess = nil
        }
        _ = await exec(args: ["dashboard", "--stop"])
    }
    
    // Save API key
    func saveApiKey(provider: String, key: String) -> Bool {
        let envVarName: String
        switch provider.lowercased() {
        case "openrouter": envVarName = "OPENROUTER_API_KEY"
        case "gemini": envVarName = "GEMINI_API_KEY"
        case "openai": envVarName = "OPENAI_API_KEY"
        case "anthropic": envVarName = "ANTHROPIC_API_KEY"
        default: return false
        }
        
        mergedEnvironment[envVarName] = key
        
        var contentLines: [String] = []
        if FileManager.default.fileExists(atPath: envPath.path) {
            do {
                let content = try String(contentsOf: envPath, encoding: .utf8)
                contentLines = content.components(separatedBy: .newlines)
            } catch {
                print("Failed to read env for update: \(error)")
            }
        }
        
        var updated = false
        for (i, line) in contentLines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("\(envVarName)=") {
                contentLines[i] = "\(envVarName)=\(key)"
                updated = true
                break
            }
        }
        
        if !updated {
            contentLines.append("\(envVarName)=\(key)")
        }
        
        do {
            let output = contentLines.joined(separator: "\n")
            try output.write(to: envPath, atomically: true, encoding: .utf8)
            return true
        } catch {
            print("Failed to save API key to file: \(error)")
            return false
        }
    }
    
    // Get API key
    func getApiKey(provider: String) -> String {
        let envVarName: String
        switch provider.lowercased() {
        case "openrouter": envVarName = "OPENROUTER_API_KEY"
        case "gemini": envVarName = "GEMINI_API_KEY"
        case "openai": envVarName = "OPENAI_API_KEY"
        case "anthropic": envVarName = "ANTHROPIC_API_KEY"
        default: return ""
        }
        return mergedEnvironment[envVarName] ?? ""
    }
    
    // Execute a CLI command synchronously
    func exec(args: [String]) async -> (success: Bool, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: hermesPath)
        process.arguments = args
        process.environment = mergedEnvironment
        
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        
        do {
            try process.run()
            
            return await withCheckedContinuation { continuation in
                process.terminationHandler = { proc in
                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    
                    let stdout = String(data: outData, encoding: .utf8) ?? ""
                    let stderr = String(data: errData, encoding: .utf8) ?? ""
                    let success = proc.terminationStatus == 0
                    
                    continuation.resume(returning: (success, stdout, stderr))
                }
            }
        } catch {
            return (false, "", error.localizedDescription)
        }
    }
    
    // Execute an arbitrary command (not the hermes binary) with the merged env.
    // Used e.g. for the LINE bridge's line-send.sh.
    func execCommand(_ launchPath: String, _ args: [String]) async -> (success: Bool, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        process.environment = mergedEnvironment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            return await withCheckedContinuation { continuation in
                process.terminationHandler = { proc in
                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let stdout = String(data: outData, encoding: .utf8) ?? ""
                    let stderr = String(data: errData, encoding: .utf8) ?? ""
                    continuation.resume(returning: (proc.terminationStatus == 0, stdout, stderr))
                }
            }
        } catch {
            return (false, "", error.localizedDescription)
        }
    }

    // Stream prompt command
    func streamPrompt(
        prompt: String,
        sessionId: String?,
        imagePath: String? = nil,
        cwd: String = NSHomeDirectory(),
        onData: @escaping @Sendable (String) -> Void,
        onStderr: @escaping @Sendable (String) -> Void,
        onEnd: @escaping @Sendable (Int32) -> Void
    ) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: hermesPath)

        var args = ["chat", "-q", prompt]
        if let img = imagePath, !img.isEmpty {
            args.append(contentsOf: ["--image", img])
        }
        if let sid = sessionId {
            args.append(contentsOf: ["--resume", sid])
        }
        process.arguments = args
        process.environment = mergedEnvironment
        // Run the agent inside the selected workspace (GitHub repo) so file/terminal
        // tools operate on it; defaults to home.
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                onData(text)
            }
        }
        
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                onStderr(text)
            }
        }
        
        process.terminationHandler = { proc in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            
            let remainingOut = outPipe.fileHandleForReading.readDataToEndOfFile()
            if !remainingOut.isEmpty, let text = String(data: remainingOut, encoding: .utf8) {
                onData(text)
            }
            
            let remainingErr = errPipe.fileHandleForReading.readDataToEndOfFile()
            if !remainingErr.isEmpty, let text = String(data: remainingErr, encoding: .utf8) {
                onStderr(text)
            }
            
            onEnd(proc.terminationStatus)
        }
        
        do {
            try process.run()
            return process
        } catch {
            print("Failed to run stream process: \(error)")
            onEnd(-1)
            return nil
        }
    }
    
    // Stream agent.log in real time
    func streamLogs(
        onData: @escaping @Sendable (String) -> Void
    ) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: hermesPath)
        process.arguments = ["logs", "-f", "--since", "5m"]
        process.environment = mergedEnvironment
        
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = outPipe
        
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                onData(text)
            }
        }
        
        process.terminationHandler = { proc in
            outPipe.fileHandleForReading.readabilityHandler = nil
            let remaining = outPipe.fileHandleForReading.readDataToEndOfFile()
            if !remaining.isEmpty, let text = String(data: remaining, encoding: .utf8) {
                onData(text)
            }
        }
        
        do {
            try process.run()
            return process
        } catch {
            print("Failed to run logs process: \(error)")
            return nil
        }
    }
}
