import Foundation

/// Pure parser for `hermes cron list` stdout. Extracted for unit testing.
enum HermesCronJobParser {
    static func parseList(stdout: String) -> [HermesCronJob] {
        var jobs: [HermesCronJob] = []
        let lines = stdout.components(separatedBy: CharacterSet.newlines)

        var currentId = ""
        var currentStatus = ""
        var currentName = ""
        var currentSchedule = ""
        var currentRepeat = ""
        var currentNextRun = ""
        var currentDeliver = ""
        var currentScript: String? = nil
        var currentMode: String? = nil
        var currentLastRun: String? = nil
        var currentLastError: String? = nil

        func saveCurrentJob() {
            if !currentId.isEmpty {
                jobs.append(HermesCronJob(
                    id: currentId,
                    name: currentName.isEmpty ? "Unnamed Job" : currentName,
                    schedule: currentSchedule,
                    repeatCount: currentRepeat,
                    nextRun: currentNextRun,
                    deliver: currentDeliver,
                    status: currentStatus,
                    script: currentScript,
                    mode: currentMode,
                    lastRun: currentLastRun,
                    lastError: currentLastError
                ))
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            let rawLine = line

            if rawLine.hasPrefix("  ") && !rawLine.hasPrefix("    ") {
                let parts = trimmed.components(separatedBy: CharacterSet.whitespaces).filter { !$0.isEmpty }
                if parts.count >= 2 {
                    let id = parts[0]
                    if id.count == 12 {
                        saveCurrentJob()
                        currentId = id
                        let statusPart = parts[1]
                        currentStatus = statusPart
                            .replacingOccurrences(of: "[", with: "")
                            .replacingOccurrences(of: "]", with: "")
                        currentName = ""
                        currentSchedule = ""
                        currentRepeat = ""
                        currentNextRun = ""
                        currentDeliver = ""
                        currentScript = nil
                        currentMode = nil
                        currentLastRun = nil
                        currentLastError = nil
                    }
                }
            } else if !currentId.isEmpty && rawLine.hasPrefix("    ") {
                if trimmed.hasPrefix("Name:") {
                    currentName = trimmed.replacingOccurrences(of: "Name:", with: "").trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("Schedule:") {
                    currentSchedule = trimmed.replacingOccurrences(of: "Schedule:", with: "").trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("Repeat:") {
                    currentRepeat = trimmed.replacingOccurrences(of: "Repeat:", with: "").trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("Next run:") {
                    currentNextRun = trimmed.replacingOccurrences(of: "Next run:", with: "").trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("Deliver:") {
                    currentDeliver = trimmed.replacingOccurrences(of: "Deliver:", with: "").trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("Script:") {
                    currentScript = trimmed.replacingOccurrences(of: "Script:", with: "").trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("Mode:") {
                    currentMode = trimmed.replacingOccurrences(of: "Mode:", with: "").trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("Last run:") {
                    currentLastRun = trimmed.replacingOccurrences(of: "Last run:", with: "").trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("⚠") || trimmed.lowercased().contains("delivery failed") {
                    currentLastError = trimmed
                        .replacingOccurrences(of: "⚠", with: "")
                        .trimmingCharacters(in: .whitespaces)
                }
            }
        }
        saveCurrentJob()
        return jobs
    }
}
