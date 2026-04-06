import Foundation

actor OllamaTranslator {
    private let claudePath: String = {
        let paths = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            NSHomeDirectory() + "/.npm-global/bin/claude",
            NSHomeDirectory() + "/.claude/local/claude",
            NSHomeDirectory() + "/.local/bin/claude"
        ]
        for p in paths {
            if FileManager.default.isExecutableFile(atPath: p) {
                NSLog("DictationApp: [TRANSLATE] found claude at %@", p)
                return p
            }
        }
        NSLog("DictationApp: [TRANSLATE] claude not found, using PATH")
        return "/usr/bin/env"
    }()

    func translate(_ text: String, mode: TranslationMode) async -> String? {
        guard mode != .off, !text.isEmpty else { return nil }

        let prompt = mode.prompt + text
        let start = ProcessInfo.processInfo.systemUptime
        let usesEnv = claudePath == "/usr/bin/env"

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [claudePath, usesEnv] in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: claudePath)

                if usesEnv {
                    process.arguments = ["claude", "-p", prompt, "--max-turns", "1", "--output-format", "text"]
                } else {
                    process.arguments = ["-p", prompt, "--max-turns", "1", "--output-format", "text"]
                }

                // Inherit user's shell environment for PATH and auth
                var env = ProcessInfo.processInfo.environment
                env["NO_COLOR"] = "1"
                env.removeValue(forKey: "CLAUDECODE")
                env.removeValue(forKey: "CLAUDE_CODE")
                env.removeValue(forKey: "CLAUDE_CODE_SESSION")
                process.environment = env

                let pipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = pipe
                process.standardError = errorPipe
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                    process.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let elapsed = ProcessInfo.processInfo.systemUptime - start

                    if process.terminationStatus == 0 && !output.isEmpty {
                        NSLog("DictationApp: [TRANSLATE] done in %.1fs (%@): '%@'", elapsed, mode.displayName, String(output.prefix(80)))
                        continuation.resume(returning: output)
                    } else {
                        let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let errStr = String(data: errData, encoding: .utf8) ?? ""
                        NSLog("DictationApp: [TRANSLATE] failed (exit %d, %.1fs): %@", process.terminationStatus, elapsed, String(errStr.prefix(200)))
                        continuation.resume(returning: nil)
                    }
                } catch {
                    NSLog("DictationApp: [TRANSLATE] error: %@", error.localizedDescription)
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
