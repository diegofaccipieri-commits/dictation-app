import Foundation
import AppKit
import NaturalLanguage

enum WhisperCppError: Error {
    case serverNotRunning
    case modelNotFound
    case cliNotFound
}

enum DictationDiagnostics {
    private static let lock = NSLock()
    private static let dateFormatter = ISO8601DateFormatter()

    static var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: "diagnosticLoggingEnabled") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "diagnosticLoggingEnabled")
    }

    static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DictationApp", isDirectory: true)
    }

    static var fragmentMergeEnabled: Bool {
        UserDefaults.standard.bool(forKey: "fragmentMergeEnabled")
    }

    static func record(_ event: String, fields: [String: Any] = [:]) {
        guard isEnabled else { return }

        var payload = fields
        let timestamp = dateFormatter.string(from: Date())
        payload["event"] = event
        payload["timestamp"] = timestamp
        payload["app_version"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        payload["build"] = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"

        do {
            try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            let day = String(timestamp.prefix(10))
            let file = logDirectory.appendingPathComponent("diagnostics-\(day).jsonl")
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            guard var line = String(data: data, encoding: .utf8) else { return }
            line.append("\n")

            lock.lock()
            defer { lock.unlock() }

            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let lineData = line.data(using: .utf8) {
                handle.write(lineData)
            }
        } catch {
            NSLog("DictationApp: [DIAG] failed to write diagnostic log: %@", error.localizedDescription)
        }
    }
}

/// Manages a whisper.cpp server process and transcribes via HTTP.
/// Model stays loaded in memory — inference is fast (~2-3s for 20s of audio).
class WhisperCppServer {
    let modelPath: String
    let serverPath: String
    let port: Int
    private var serverProcess: Process?

    init(modelPath: String, serverPath: String, port: Int = 8178) throws {
        guard FileManager.default.fileExists(atPath: serverPath) else {
            throw WhisperCppError.cliNotFound
        }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw WhisperCppError.modelNotFound
        }
        self.modelPath = modelPath
        self.serverPath = serverPath
        self.port = port
    }

    /// Start the server process in background. Model loads once.
    func start() {
        guard serverProcess == nil else { return }

        let maxThreads = 4 // M1 Pro: Metal handles inference, 4 CPU threads optimal

        let process = Process()
        process.executableURL = URL(fileURLWithPath: serverPath)
        process.arguments = [
            "-m", modelPath,
            "--port", String(port),
            "-t", String(maxThreads),
            "-fa",              // flash attention — faster inference on Apple Silicon
            "--split-on-word",  // if wrapping is re-enabled, never split inside a word
            "--max-len", "500", // keep server-side line breaks away from normal dictation words
            "--beam-size", "1", // greedy decoding — ~50% faster, quality same for dictation
            "--best-of", "1",   // no sampling candidates
            "--no-speech-thold", "0.3",
            "--language", "auto", // per-request language selects auto/pt/en/es
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            serverProcess = process
            NSLog("DictationApp: [WCPP] server started on port %d (PID %d)", port, process.processIdentifier)
        } catch {
            NSLog("DictationApp: [WCPP] failed to start server: %@", error.localizedDescription)
        }
    }

    /// Stop the server process.
    func stop() {
        serverProcess?.terminate()
        serverProcess = nil
        NSLog("DictationApp: [WCPP] server stopped")
    }

    /// Wait for the server to be ready (model loaded).
    func waitUntilReady(timeout: TimeInterval = 120) async -> Bool {
        let start = Date()
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        while Date().timeIntervalSince(start) < timeout {
            var request = URLRequest(url: url)
            request.timeoutInterval = 2
            let ok: Bool
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                ok = (response as? HTTPURLResponse)?.statusCode == 200
            } catch {
                ok = false
            }
            if ok {
                NSLog("DictationApp: [WCPP] server ready (%.1fs)", Date().timeIntervalSince(start))
                return true
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        NSLog("DictationApp: [WCPP] server not ready after %.0fs", timeout)
        return false
    }

    /// Transcribe 16kHz mono Float samples via HTTP POST to the server.
    func transcribe(samples: [Float],
                    language: String = TranscriptionLanguage.current.whisperCode,
                    prompt: String? = nil) async -> String {
        let diagnosticID = UUID().uuidString
        let duration = Double(samples.count) / 16000.0
        NSLog("DictationApp: [WCPP] transcribing %d samples (%.1fs) via server",
              samples.count, duration)
        DictationDiagnostics.record("whisper_request", fields: [
            "diagnostic_id": diagnosticID,
            "sample_count": samples.count,
            "duration_seconds": duration,
            "language": language,
            "split_on_word": true,
            "no_timestamps": false,
            "max_len": 500
        ])

        // Build WAV data in memory (no disk I/O)
        let wavData = WhisperCppServer.wavData(from: samples)

        // Build multipart form request
        let boundary = UUID().uuidString
        let url = URL(string: "http://127.0.0.1:\(port)/inference")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = max(120, min(1_800, duration * 12 + 60))

        var body = Data()
        // File field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)
        appendFormField(name: "response_format", value: "text", boundary: boundary, to: &body)
        appendFormField(name: "language", value: language, boundary: boundary, to: &body)
        appendFormField(name: "split_on_word", value: "true", boundary: boundary, to: &body)
        appendFormField(name: "max_len", value: "500", boundary: boundary, to: &body)
        appendFormField(name: "temperature", value: "0", boundary: boundary, to: &body)
        appendFormField(name: "suppress_nst", value: "true", boundary: boundary, to: &body)
        let promptText = prompt ?? Self.defaultPrompt(for: language)
        if !promptText.isEmpty {
            appendFormField(name: "prompt", value: promptText, boundary: boundary, to: &body)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        var responseText = ""
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let text = String(data: data, encoding: .utf8) {
                responseText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            NSLog("DictationApp: [WCPP] HTTP error: %@", error.localizedDescription)
            DictationDiagnostics.record("whisper_error", fields: [
                "diagnostic_id": diagnosticID,
                "duration_seconds": duration,
                "error": error.localizedDescription
            ])
        }

        let lines = responseText.components(separatedBy: "\n")
        var cleaned = Self.joinTranscriptionParts(lines)

        let normalizedText = cleaned
        let mergeEnabled = DictationDiagnostics.fragmentMergeEnabled
        if mergeEnabled {
            // Optional repair for words split by the tokenizer (e.g. "mens agem" -> "mensagem").
            // Disabled by default while we validate whether Whisper's direct output is already better.
            cleaned = WhisperCppServer.mergeFragmentedWords(cleaned)
        }

        NSLog("DictationApp: [WCPP] server returned %d chars: '%@'", cleaned.count, String(cleaned.prefix(100)))
        DictationDiagnostics.record("whisper_response", fields: [
            "diagnostic_id": diagnosticID,
            "raw_text": responseText,
            "normalized_text": normalizedText,
            "cleaned_text": cleaned,
            "fragment_merge_enabled": mergeEnabled,
            "raw_length": responseText.count,
            "cleaned_length": cleaned.count,
            "line_count": lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        ])
        return cleaned
    }

    private func appendFormField(name: String, value: String, boundary: String, to body: inout Data) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(value)\r\n".data(using: .utf8)!)
    }

    static func defaultPrompt(for language: String) -> String {
        switch language {
        case "pt":
            return "Ditado em português do Brasil. Use palavras completas, ortografia correta e pontuação adequada. Preserve nomes próprios, marcas e termos técnicos em inglês quando forem ditos."
        case "en":
            return "Dictation in English. Use complete words, correct spelling and proper punctuation."
        case "es":
            return "Dictado en español. Usa palabras completas, ortografía correcta y puntuación adecuada."
        default:
            return ""
        }
    }

    static func joinTranscriptionParts(_ parts: [String]) -> String {
        var result = ""
        for part in parts {
            var text = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            if result.isEmpty {
                result = text
                continue
            }

            if !endsSentence(result) {
                text = lowercasedForContinuation(text)
            }
            result += " " + text
        }
        return result
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return last == "." || last == "?" || last == "!" || last == "…"
    }

    private static func lowercasedForContinuation(_ text: String) -> String {
        guard let firstIndex = text.firstIndex(where: { $0.isLetter }) else { return text }
        let firstWord = text[firstIndex...].prefix { $0.isLetter }
        if firstWord == "I" { return text }
        if firstWord.count >= 2 && firstWord.count <= 5 && firstWord.allSatisfy({ $0.isUppercase }) { return text }

        var out = text
        out.replaceSubrange(firstIndex...firstIndex, with: String(out[firstIndex]).lowercased())
        return out
    }

    deinit {
        stop()
    }

    // MARK: - Word fragment merger

    /// Merge tokenizer-split words using macOS spell checker + language detection.
    /// Detects the dominant language first, then checks spelling in that language.
    /// Merges when at least one fragment is misspelled and the joined word is valid.
    // Suffixes/endings that never start a standalone word — bypass spell check for these.
    private static let knownSuffixes: Set<String> = [
        // Portuguese endings
        "ção", "ções", "são", "sões", "nhão", "nhões", "agem", "mente",
        "ação", "ações",                        // documentação, informação, etc.
        "amento", "amentos", "imento", "imentos", // pagamento, requerimento, etc.
        "ário", "ária", "ários", "árias", "dade", "tura",
        "amente", "iamente",                    // obrigatoriamente, rapidamente, etc.
        "eiro", "eira", "eiros", "eiras",
        "entes", "ores", "oras", "idos", "idas",
        "ando", "endo", "indo",
        "ingo", "ingos", "inga", "ingas",       // domingo, flamingo, etc.
        "inho", "inha", "inhos", "inhas",
        "zinho", "zinha", "zinhos", "zinhas",
        "ado", "ada", "ados", "adas",           // bacharelado, qualificado, etc.
        "ificado", "ificada", "ificados", "ificadas",
        "quela", "quele", "quelas", "queles",   // naquela, naquele (contrações)
        // English endings
        "tion", "tions", "ness", "ment", "ments",
    ]

    static func mergeFragmentedWords(_ text: String) -> String {
        let checker = NSSpellChecker.shared
        let words = text.components(separatedBy: " ")
        guard words.count >= 2 else { return text }

        let lang = normalizedLanguage(for: text)
        NSLog("DictationApp: [WCPP] mergeFragmentedWords: detected language '%@'", lang)

        var result: [String] = []
        var i = 0
        while i < words.count {
            if i + 1 < words.count {
                let a = words[i]
                // Detach trailing punctuation from the second fragment ("ian." → "ian" + ".")
                // so a sentence-final split like "Líl ian." can still merge, then reattach it.
                let bRaw = words[i + 1]
                let bCore = String(bRaw.unicodeScalars.prefix { CharacterSet.letters.contains($0) })
                let bTrail = String(bRaw.dropFirst(bCore.count))
                let joined = a + bCore

                let aLetters = a.allSatisfy { $0.isLetter }
                let bLetters = !bCore.isEmpty && bCore.allSatisfy { $0.isLetter }
                let bIsSuffix = knownSuffixes.contains(bCore.lowercased())

                // Known suffix: always attempt merge (bypasses length limit and spell check on b).
                // Regular fragment: both short, check spelling.
                let couldBeFragment = aLetters && bLetters && a.count >= 2
                    && (bIsSuffix || (a.count <= 9 && joined.count <= 18))

                if couldBeFragment {
                    // A fragment counts as a split-signal when misspelled in the DETECTED
                    // language only (no Portuguese fallback) — otherwise a foreign-looking
                    // fragment like "document" gets masked as valid and the merge is skipped.
                    let aMisspelled = !bIsSuffix && !isSpelled(a, lang: lang, checker: checker, allowPortugueseFallback: false)
                    let bMisspelled = bIsSuffix || !isSpelled(bCore, lang: lang, checker: checker, allowPortugueseFallback: false)

                    if aMisspelled || bMisspelled || shouldTryPortugueseJoin(a: a, b: bCore, joined: joined, lang: lang, checker: checker) {
                        if let merged = resolveMerge(a: a, b: bCore, joined: joined, bIsSuffix: bIsSuffix, lang: lang, checker: checker) {
                            NSLog("DictationApp: [WCPP] merged: '%@' + '%@' → '%@' [%@]", a, bRaw, merged + bTrail, lang)
                            result.append(merged + bTrail)
                            i += 2
                            continue
                        }
                    }
                }
            }
            result.append(words[i])
            i += 1
        }
        return result.joined(separator: " ")
    }

    /// True if `word` is spelled correctly in `lang`. When `allowPortugueseFallback`
    /// is true, also accept words valid in Portuguese (used to validate a merged word);
    /// when false, judge strictly in the detected language (used to flag split fragments).
    private static func isSpelled(_ word: String, lang: String, checker: NSSpellChecker,
                                  allowPortugueseFallback: Bool = true) -> Bool {
        func ok(_ l: String) -> Bool {
            checker.checkSpelling(of: word, startingAt: 0, language: l, wrap: false,
                                  inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
        if ok(lang) { return true }
        return allowPortugueseFallback && lang != "pt" && ok("pt")
    }

    /// Some bad splits are two valid standalone words in the spell checker, e.g.
    /// "client e" -> "cliente", "process o" -> "processo".
    /// Only do this for Portuguese-biased text and only when the joined form is a
    /// valid Portuguese word, otherwise common phrases such as "com o" are unsafe.
    private static func shouldTryPortugueseJoin(a: String, b: String, joined: String,
                                                lang: String, checker: NSSpellChecker) -> Bool {
        guard lang == "pt" else { return false }
        guard a.count >= 3, b.count <= 3, joined.count <= 18 else { return false }

        let lowerA = a.lowercased()
        let lowerB = b.lowercased()
        let standaloneSecondWords: Set<String> = [
            "do", "da", "de", "dos", "das",
            "no", "na", "nos", "nas",
            "ao", "aos", "às"
        ]
        if standaloneSecondWords.contains(lowerB)
            && isSpelled(a, lang: "pt_BR", checker: checker, allowPortugueseFallback: true) {
            return false
        }

        let unsafePairs: Set<String> = [
            "com o", "com a", "com os", "com as",
            "por o", "por a", "por os", "por as"
        ]
        guard !unsafePairs.contains("\(lowerA) \(lowerB)") else { return false }

        return isSpelled(joined, lang: "pt_BR", checker: checker, allowPortugueseFallback: true)
            || isSpelled(joined, lang: "pt", checker: checker, allowPortugueseFallback: false)
    }

    /// Strip diacritics (e.g. "rápida" → "rapida"), using Brazilian Portuguese rules.
    private static func deaccent(_ s: String) -> String {
        s.folding(options: .diacriticInsensitive, locale: Locale(identifier: "pt_BR"))
    }

    /// Resolve the correct merged spelling of two fragments, or nil if no confident merge.
    /// Order: (1) naive join, (2) base with accent dropped — pt adverbs drop the base
    /// accent ("rápida"+"mente" → "rapidamente"), (3) spell-checker suggestion, accepted
    /// only if it keeps the suffix and shares the base's stem so we never invent a new word.
    private static func resolveMerge(a: String, b: String, joined: String,
                                     bIsSuffix: Bool, lang: String, checker: NSSpellChecker) -> String? {
        // 1. Naive concatenation already valid.
        if isSpelled(joined, lang: lang, checker: checker) { return joined }
        guard bIsSuffix else { return nil }  // only known suffixes get the extra repair attempts

        // 2. Drop the base's accent.
        let deAccented = deaccent(a) + b
        if deAccented != joined && isSpelled(deAccented, lang: lang, checker: checker) {
            return deAccented
        }

        // 3. Spell-checker suggestion, guarded by suffix + stem match.
        let bLower = b.lowercased()
        let stem = String(deaccent(a).lowercased().prefix(3))
        let langsToTry = lang == "pt" ? ["pt_BR", "pt"] : [lang, "pt_BR", "pt"]
        let ns = joined as NSString
        for l in langsToTry {
            let guesses = checker.guesses(forWordRange: NSRange(location: 0, length: ns.length),
                                          in: joined, language: l, inSpellDocumentWithTag: 0) ?? []
            for g in guesses {
                let gLower = g.lowercased()
                if gLower.hasSuffix(bLower)
                    && deaccent(gLower).hasPrefix(stem)
                    && abs(g.count - joined.count) <= 3 {
                    return g
                }
            }
        }
        return nil
    }

    /// Detect dominant language, then normalize toward the app's primary dictation
    /// language. NLLanguageRecognizer often returns ca/it/es for short Portuguese
    /// fragments, which makes spell-check based joining choose the wrong spelling.
    private static func normalizedLanguage(for text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let raw = recognizer.dominantLanguage?.rawValue else { return "pt" }
        switch raw {
        case "pt", "en":
            return raw
        default:
            return "pt"
        }
    }

    // MARK: - WAV helper

    /// Build WAV data in memory — no disk I/O needed.
    static func wavData(from samples: [Float]) -> Data {
        let sr: Int32 = 16000
        let bitsPerSample: Int16 = 16
        let numChannels: Int16 = 1
        let dataSize = Int32(samples.count * 2)
        let fileSize = 36 + dataSize

        var data = Data()
        data.reserveCapacity(44 + Int(dataSize))
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: Int32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: Int16(1).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: sr.littleEndian) { Array($0) })
        let byteRate = sr * Int32(numChannels) * Int32(bitsPerSample / 8)
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        let blockAlign = numChannels * (bitsPerSample / 8)
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })

        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            let int16 = Int16(clamped * 32767.0)
            data.append(contentsOf: withUnsafeBytes(of: int16.littleEndian) { Array($0) })
        }

        return data
    }

    static func saveWav(samples: [Float], to url: URL) {
        let sr: Int32 = 16000
        let bitsPerSample: Int16 = 16
        let numChannels: Int16 = 1
        let dataSize = Int32(samples.count * 2)
        let fileSize = 36 + dataSize

        var data = Data()
        data.reserveCapacity(44 + Int(dataSize))
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: Int32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: Int16(1).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: sr.littleEndian) { Array($0) })
        let byteRate = sr * Int32(numChannels) * Int32(bitsPerSample / 8)
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        let blockAlign = numChannels * (bitsPerSample / 8)
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })

        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            let int16 = Int16(clamped * 32767.0)
            data.append(contentsOf: withUnsafeBytes(of: int16.littleEndian) { Array($0) })
        }

        try? data.write(to: url)
    }
}

/// Batch/file transcription via the bundled `whisper-cli` (the same whisper.cpp engine that powers
/// live dictation). Used INSTEAD of WhisperKit for file & Voice-Memos transcription because
/// WhisperKit's CoreML model load deadlocks on macOS 26.x (`MLE5ProgramLibrary.lazyInitQueue`).
/// It runs as a separate process, handles multi-hour files, and emits timestamped segments via `-oj`.
enum WhisperCppCLI {

    struct Segment {
        let start: Double   // seconds
        let end: Double     // seconds
        let text: String
    }

    enum CLIError: LocalizedError {
        case binaryMissing, modelMissing, failed(Int32), noOutput
        var errorDescription: String? {
            switch self {
            case .binaryMissing: return "whisper-cli não encontrado no app"
            case .modelMissing:  return "modelo whisper.cpp não encontrado"
            case .failed(let c): return "whisper-cli falhou (código \(c))"
            case .noOutput:      return "whisper-cli não gerou saída"
            }
        }
    }

    static var cliPath: String { (Bundle.main.resourcePath ?? "") + "/whisper-cli" }
    static var modelPath: String {
        NSHomeDirectory() + "/Documents/huggingface/models/whisper.cpp/ggml-large-v3-turbo-q5_0.bin"
    }

    /// Transcribe a 16 kHz mono WAV into timestamped segments. `onProgress` receives 0–100.
    static func transcribeSegments(wav: URL,
                                   language: String = "auto",
                                   onProgress: ((Int) -> Void)? = nil) async throws -> [Segment] {
        guard FileManager.default.isExecutableFile(atPath: cliPath) else { throw CLIError.binaryMissing }
        guard FileManager.default.fileExists(atPath: modelPath) else { throw CLIError.modelMissing }

        let outBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("wcli-\(UUID().uuidString)")
        let jsonURL = URL(fileURLWithPath: outBase.path + ".json")
        defer { try? FileManager.default.removeItem(at: jsonURL) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cliPath)
        proc.arguments = [
            "-m", modelPath,
            "-f", wav.path,
            "-oj", "-of", outBase.path,
            "-l", language,
            "-t", "4",
            "-bs", "1", "-bo", "1",   // greedy: fast, fine for transcription
            "--print-progress",
        ]
        proc.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        proc.standardError = errPipe

        errPipe.fileHandleForReading.readabilityHandler = { handle in
            guard let onProgress,
                  let s = String(data: handle.availableData, encoding: .utf8) else { return }
            for line in s.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                if let r = line.range(of: "progress = ") {
                    let digits = line[r.upperBound...].prefix { $0.isNumber }
                    if let pct = Int(digits) { onProgress(min(pct, 99)) }
                }
            }
        }

        try proc.run()
        await Task.detached(priority: .utility) { proc.waitUntilExit() }.value
        errPipe.fileHandleForReading.readabilityHandler = nil

        guard proc.terminationStatus == 0 else { throw CLIError.failed(proc.terminationStatus) }
        guard let data = try? Data(contentsOf: jsonURL) else { throw CLIError.noOutput }

        struct Out: Decodable {
            struct Seg: Decodable {
                struct Offsets: Decodable { let from: Int; let to: Int }
                let offsets: Offsets
                let text: String
            }
            let transcription: [Seg]
        }
        let out = try JSONDecoder().decode(Out.self, from: data)
        return out.transcription.map {
            Segment(start: Double($0.offsets.from) / 1000.0,
                    end: Double($0.offsets.to) / 1000.0,
                    text: $0.text)
        }
    }
}
