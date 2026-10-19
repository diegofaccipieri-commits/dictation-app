import Foundation

// Persistent Claude CLI process in stream-json mode. The CLI boots once (~4-6s of
// Node + harness cold start) and then serves each translation as a new message on
// stdin, so a warm translation costs only the model inference (~1-3s). Each
// stream-json message starts a fresh session inside the same process, so no
// context accumulates between translations. The process is dropped after
// `idleTimeout` without a translation: kept warm it held ~130 MB around the clock.
actor ClaudeTranslator {
    private let timeout: TimeInterval = 30
    private let idleTimeout: TimeInterval = 10 * 60
    private var idleTeardown: Task<Void, Never>?

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var currentModel = ""
    private var lineParser: StreamLineParser?
    private var pending: PendingResult?

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
        return found + ["/usr/bin/env"]
    }()

    // LAWYER produces legal correspondence, keep the stronger model there.
    private func model(for mode: TranslationMode) -> String {
        mode == .lawyer ? "claude-sonnet-5-5" : "claude-haiku-5-5"
    }

    // Boot the CLI ahead of time so the first translation is already warm.
    func warmUp(mode: TranslationMode) {
        guard mode != .off else { return }
        ensureProcess(model: model(for: mode))
        scheduleIdleTeardown()
    }

    private func scheduleIdleTeardown() {
        idleTeardown?.cancel()
        idleTeardown = Task {
            try? await Task.sleep(nanoseconds: UInt64(idleTimeout * 1_000_000_000))
            guard !Task.isCancelled, pending == nil, process != nil else { return }
            NSLog("DictationApp: [TRANSLATE] no translation for %.0f min; dropping the claude process", idleTimeout / 60)
            teardown()
        }
    }

    func translate(_ text: String, mode: TranslationMode) async -> String? {
        guard mode != .off, !text.isEmpty else { return nil }

        let prompt = """
        You are a deterministic translation function for a dictation app.
        Translate the text exactly as requested.
        Return ONLY the translated text.
        Do not add explanations, markdown, labels, quotes, comments, or alternative versions.

        \(mode.prompt)\(text)
        """
        let requestedModel = model(for: mode)
        let start = ProcessInfo.processInfo.systemUptime
        defer { scheduleIdleTeardown() }

        // First attempt on the warm process; on failure recycle and retry once cold.
        for attempt in 1...2 {
            ensureProcess(model: requestedModel)
            if let translated = await sendAndWait(prompt: prompt) {
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                NSLog("DictationApp: [TRANSLATE] done in %.1fs (%@, model=%@, attempt %d): '%@'",
                      elapsed, mode.displayName, requestedModel, attempt, String(translated.prefix(80)))
                return translated
            }
            NSLog("DictationApp: [TRANSLATE] attempt %d failed — recycling claude process", attempt)
            teardown()
        }
        return nil
    }

    // MARK: - Process lifecycle

    private func ensureProcess(model: String) {
        if let p = process, p.isRunning, currentModel == model { return }
        teardown()

        for candidate in claudeCandidates {
            if spawn(candidate: candidate, model: model) {
                currentModel = model
                NSLog("DictationApp: [TRANSLATE] warm claude process started (model=%@) via %@", model, candidate)
                return
            }
        }
        NSLog("DictationApp: [TRANSLATE] could not start any claude candidate")
    }

    private func spawn(candidate: String, model: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: candidate)
        p.currentDirectoryURL = FileManager.default.temporaryDirectory

        // --strict-mcp-config: skip the user's MCP servers (their boot added 18-25s).
        // stream-json input keeps the process alive waiting for messages on stdin.
        let baseArgs = ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                        "--verbose", "--model", model, "--max-turns", "1",
                        "--no-session-persistence", "--strict-mcp-config"]
        p.arguments = candidate == "/usr/bin/env" ? ["claude"] + baseArgs : baseArgs

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
        p.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        p.standardInput = stdinPipe
        p.standardOutput = stdoutPipe
        p.standardError = FileHandle.nullDevice

        let parser = StreamLineParser { [weak self] resultText in
            guard let self else { return }
            Task { await self.deliver(resultText) }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }   // EOF: Foundation would keep calling us
            parser.feed(data)
        }

        p.terminationHandler = { [weak self] proc in
            NSLog("DictationApp: [TRANSLATE] claude process exited (status %d)", proc.terminationStatus)
            guard let self else { return }
            Task { await self.handleTermination() }
        }

        do {
            try p.run()
        } catch {
            NSLog("DictationApp: [TRANSLATE] spawn failed via %@: %@", candidate, error.localizedDescription)
            return false
        }

        process = p
        stdinHandle = stdinPipe.fileHandleForWriting
        lineParser = parser
        return true
    }

    private func teardown() {
        pending?.resume(nil)
        pending = nil
        if let p = process {
            p.terminationHandler = nil
            (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            if p.isRunning {
                p.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                }
            }
        }
        try? stdinHandle?.close()
        stdinHandle = nil
        process = nil
        lineParser = nil
        currentModel = ""
    }

    private func handleTermination() {
        pending?.resume(nil)
        pending = nil
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil
        stdinHandle = nil
        lineParser = nil
        currentModel = ""
    }

    private func deliver(_ result: String?) {
        pending?.resume(result)
        pending = nil
    }

    // MARK: - Request

    private func sendAndWait(prompt: String) async -> String? {
        guard let stdinHandle, process?.isRunning == true else { return nil }

        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": prompt]]]
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        data.append(0x0A)

        let box = PendingResult()
        pending = box

        do {
            try stdinHandle.write(contentsOf: data)
        } catch {
            NSLog("DictationApp: [TRANSLATE] stdin write failed: %@", error.localizedDescription)
            pending = nil
            return nil
        }

        let requestTimeout = timeout
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            box.attach(continuation)
            Task {
                try? await Task.sleep(nanoseconds: UInt64(requestTimeout * 1_000_000_000))
                box.resume(nil)  // no-op if already resumed
            }
        }
    }
}

// Resolves a translation request exactly once, from either the stdout parser,
// the termination handler, or the timeout task.
private final class PendingResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?
    private var value: String??

    func attach(_ cont: CheckedContinuation<String?, Never>) {
        lock.lock()
        if let value {
            lock.unlock()
            cont.resume(returning: value)
            return
        }
        continuation = cont
        lock.unlock()
    }

    func resume(_ result: String?) {
        lock.lock()
        guard value == nil else { lock.unlock(); return }
        value = .some(result)
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: result)
    }
}

// Accumulates stdout bytes, splits on newlines, and extracts the "result" event
// that the CLI emits at the end of each turn in stream-json mode.
private final class StreamLineParser: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let onResult: (String?) -> Void

    init(onResult: @escaping (String?) -> Void) {
        self.onResult = onResult
    }

    func feed(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let idx = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer.subdata(in: buffer.startIndex..<idx))
            buffer.removeSubrange(buffer.startIndex...idx)
        }
        lock.unlock()

        for line in lines {
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  obj["type"] as? String == "result" else { continue }
            let isError = (obj["is_error"] as? Bool) ?? false
            let text = (obj["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if isError || text == nil || text!.isEmpty {
                NSLog("DictationApp: [TRANSLATE] result event without text (is_error=%d)", isError ? 1 : 0)
                onResult(nil)
            } else {
                onResult(text)
            }
        }
    }
}
