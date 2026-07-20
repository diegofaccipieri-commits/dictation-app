import Foundation

actor ClaudeTranslator {
    private let timeout: TimeInterval = 60
    private let translationModel = "sonnet"

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

        let prompt = """
        You are a deterministic translation function for a dictation app.
        Translate the text exactly as requested.
        Return ONLY the translated text.
        Do not add explanations, markdown, labels, quotes, comments, or alternative versions.

        \(mode.prompt)\(text)
        """
        let start = ProcessInfo.processInfo.systemUptime
        for candidate in claudeCandidates {
            if let translated = await runClaude(prompt: prompt, using: candidate) {
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                NSLog("DictationApp: [TRANSLATE] done in %.1fs (%@, model=%@) via %@: '%@'", elapsed, mode.displayName, translationModel, candidate, String(translated.prefix(80)))
                return translated
            }
        }
        return nil
    }

    private func runClaude(prompt: String, using candidate: String) async -> String? {
        let usesEnv = candidate == "/usr/bin/env"
        let commandTimeout = timeout
        let model = translationModel
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: candidate)
                process.currentDirectoryURL = FileManager.default.temporaryDirectory

                // --strict-mcp-config: skip loading the user's MCP servers. Translation needs none of
                // them, and booting all of them (Google, Zoom, WhatsApp, peers, etc.) added ~18-25s of
                // cold-start per translation. With this flag a translation drops from ~30s to ~7s.
                let baseArgs = ["-p", prompt, "--max-turns", "1", "--output-format", "text",
                                "--model", model, "--no-session-persistence", "--strict-mcp-config"]
                process.arguments = usesEnv ? ["claude"] + baseArgs : baseArgs

                var env = ProcessInfo.processInfo.environment
                let currentPath = env["PATH"] ?? ""
                let extraPath = [
                    "/opt/homebrew/bin",
                    "/usr/local/bin",
                    NSHomeDirectory() + "/.local/bin",
                    NSHomeDirectory() + "/.npm-global/bin",
                    NSHomeDirectory() + "/.claude/local",
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
                    let deadline = Date().addingTimeInterval(commandTimeout)
                    while process.isRunning && Date() < deadline {
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                    if process.isRunning {
                        process.terminate()
                        Thread.sleep(forTimeInterval: 0.1)
                        if process.isRunning {
                            kill(process.processIdentifier, SIGKILL)
                        }
                        NSLog("DictationApp: [TRANSLATE] timeout via claude %@", candidate)
                        continuation.resume(returning: nil)
                        return
                    }

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if process.terminationStatus == 0 && !output.isEmpty {
                        continuation.resume(returning: output)
                        return
                    }

                    let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let errStr = String(data: errData, encoding: .utf8) ?? ""
                    NSLog("DictationApp: [TRANSLATE] failed via claude %@ (exit %d): %@", candidate, process.terminationStatus, String(errStr.prefix(300)))
                    continuation.resume(returning: nil)
                } catch {
                    NSLog("DictationApp: [TRANSLATE] error via claude %@: %@", candidate, error.localizedDescription)
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
