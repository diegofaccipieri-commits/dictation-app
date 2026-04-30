import Foundation

actor OllamaTranslator {
    private let claudeCandidates: [String] = {
        let paths = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            NSHomeDirectory() + "/.npm-global/bin/claude",
            NSHomeDirectory() + "/.claude/local/claude",
            NSHomeDirectory() + "/.local/bin/claude"
        ]
        let found = paths.filter { FileManager.default.isExecutableFile(atPath: $0) }
        if found.isEmpty {
            NSLog("DictationApp: [TRANSLATE] claude not found in fixed paths, trying PATH")
            return ["/usr/bin/env"]
        }
        NSLog("DictationApp: [TRANSLATE] claude candidates: %@", found.joined(separator: ", "))
        return found + ["/usr/bin/env"]
    }()

    func translate(_ text: String, mode: TranslationMode) async -> String? {
        guard mode != .off, !text.isEmpty else { return nil }

        let prompt = mode.prompt + text
        let start = ProcessInfo.processInfo.systemUptime
        for candidate in claudeCandidates {
            if let translated = await runClaude(prompt: prompt, using: candidate) {
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                NSLog("DictationApp: [TRANSLATE] done in %.1fs (%@) via %@: '%@'", elapsed, mode.displayName, candidate, String(translated.prefix(80)))
                return translated
            }
        }
        return nil
    }

    private func runClaude(prompt: String, using candidate: String) async -> String? {
        let usesEnv = candidate == "/usr/bin/env"
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: candidate)
                if usesEnv {
                    process.arguments = ["claude", "-p", prompt, "--max-turns", "1", "--output-format", "text"]
                } else {
                    process.arguments = ["-p", prompt, "--max-turns", "1", "--output-format", "text"]
                }

                var env = ProcessInfo.processInfo.environment
                let currentPath = env["PATH"] ?? ""
                let extraPath = [
                    "/opt/homebrew/bin",
                    "/usr/local/bin",
                    NSHomeDirectory() + "/.local/bin",
                    NSHomeDirectory() + "/.npm-global/bin",
                ].joined(separator: ":")
                env["PATH"] = currentPath.isEmpty ? extraPath : "\(currentPath):\(extraPath)"
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
                    if process.terminationStatus == 0 && !output.isEmpty {
                        continuation.resume(returning: output)
                        return
                    }
                    let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let errStr = String(data: errData, encoding: .utf8) ?? ""
                    NSLog("DictationApp: [TRANSLATE] failed via %@ (exit %d): %@", candidate, process.terminationStatus, String(errStr.prefix(200)))
                    continuation.resume(returning: nil)
                } catch {
                    NSLog("DictationApp: [TRANSLATE] error via %@: %@", candidate, error.localizedDescription)
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
