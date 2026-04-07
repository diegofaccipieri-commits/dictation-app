import Foundation
import AppKit
import NaturalLanguage

enum WhisperCppError: Error {
    case serverNotRunning
    case modelNotFound
    case cliNotFound
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

        let maxThreads = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: serverPath)
        process.arguments = [
            "-m", modelPath,
            "--port", String(port),
            "-t", String(maxThreads),
            "-fa",              // flash attention — faster inference on Apple Silicon
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
    func waitUntilReady(timeout: TimeInterval = 120) -> Bool {
        let start = Date()
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        while Date().timeIntervalSince(start) < timeout {
            var request = URLRequest(url: url)
            request.timeoutInterval = 2
            let semaphore = DispatchSemaphore(value: 0)
            var ok = false
            URLSession.shared.dataTask(with: request) { _, response, _ in
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    ok = true
                }
                semaphore.signal()
            }.resume()
            semaphore.wait()
            if ok {
                NSLog("DictationApp: [WCPP] server ready (%.1fs)", Date().timeIntervalSince(start))
                return true
            }
            Thread.sleep(forTimeInterval: 1)
        }
        NSLog("DictationApp: [WCPP] server not ready after %.0fs", timeout)
        return false
    }

    /// Transcribe 16kHz mono Float samples via HTTP POST to the server.
    func transcribe(samples: [Float]) -> String {
        NSLog("DictationApp: [WCPP] transcribing %d samples (%.1fs) via server",
              samples.count, Double(samples.count) / 16000.0)

        // Build WAV data in memory (no disk I/O)
        let wavData = WhisperCppServer.wavData(from: samples)

        // Build multipart form request
        let boundary = UUID().uuidString
        let url = URL(string: "http://127.0.0.1:\(port)/inference")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        var body = Data()
        // File field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)
        // response_format field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("text\r\n".data(using: .utf8)!)
        // language field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
        body.append("auto\r\n".data(using: .utf8)!)
        // initial prompt - guides spelling quality, biased toward Portuguese
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n".data(using: .utf8)!)
        body.append("Ditado com ortografia correta, palavras completas, pontuação adequada.\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        // Synchronous request
        let semaphore = DispatchSemaphore(value: 0)
        var responseText = ""
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let data, let text = String(data: data, encoding: .utf8) {
                responseText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let error {
                NSLog("DictationApp: [WCPP] HTTP error: %@", error.localizedDescription)
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()

        // Join newline-separated segments with spaces, then merge tokenizer splits via spell checker.
        let lines = responseText.components(separatedBy: "\n")
        var cleaned = lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)

        // Fix words split by the tokenizer (e.g. "mens agem" → "mensagem").
        cleaned = WhisperCppServer.mergeFragmentedWords(cleaned)

        NSLog("DictationApp: [WCPP] server returned %d chars: '%@'", cleaned.count, String(cleaned.prefix(100)))
        return cleaned
    }

    deinit {
        stop()
    }

    // MARK: - Word fragment merger

    /// Merge tokenizer-split words using macOS spell checker + language detection.
    /// Detects the dominant language first, then checks spelling in that language.
    /// Merges when at least one fragment is misspelled and the joined word is valid.
    static func mergeFragmentedWords(_ text: String) -> String {
        let checker = NSSpellChecker.shared
        let words = text.components(separatedBy: " ")
        guard words.count >= 2 else { return text }

        // Detect dominant language so we check spelling in the right dictionary
        let lang = detectLanguage(text)
        NSLog("DictationApp: [WCPP] mergeFragmentedWords: detected language '%@'", lang)

        var result: [String] = []
        var i = 0
        while i < words.count {
            if i + 1 < words.count {
                let a = words[i]
                let b = words[i + 1]
                let joined = a + b

                // Only attempt merge when both fragments look like word parts (letters only, 2+ chars)
                let aLetters = a.allSatisfy { $0.isLetter }
                let bLetters = b.allSatisfy { $0.isLetter }

                if aLetters && bLetters && a.count >= 2 && b.count >= 2 {
                    let aMisspelled = checker.checkSpelling(of: a, startingAt: 0, language: lang, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location != NSNotFound
                    let bMisspelled = checker.checkSpelling(of: b, startingAt: 0, language: lang, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location != NSNotFound
                    let joinedValid = checker.checkSpelling(of: joined, startingAt: 0, language: lang, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound

                    // Only merge when BOTH fragments are misspelled AND joined word is valid.
                    // This prevents merging valid words like "verificar" + "a" → "verificara"
                    if aMisspelled && bMisspelled && joinedValid {
                        NSLog("DictationApp: [WCPP] merged fragments: '%@' + '%@' → '%@' [%@]", a, b, joined, lang)
                        result.append(joined)
                        i += 2
                        continue
                    }
                }
            }
            result.append(words[i])
            i += 1
        }
        return result.joined(separator: " ")
    }

    /// Detect dominant language of text using NLLanguageRecognizer.
    private static func detectLanguage(_ text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let lang = recognizer.dominantLanguage else { return "en" }
        return lang.rawValue
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
