import Foundation

enum DictationEngine: String, CaseIterable, Identifiable {
    case voxtral
    case whisper

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .voxtral: return "Voxtral (ao vivo)"
        case .whisper: return "Whisper"
        }
    }

    static var current: DictationEngine {
        DictationEngine(rawValue: UserDefaults.standard.string(forKey: "dictationEngine") ?? "") ?? .voxtral
    }
}

/// Keeps a voxtral-server process (ExecuTorch + Metal) alive with the model loaded, and streams
/// dictation audio to it so the transcript appears while the user is still speaking.
///
/// stdin protocol (little-endian): 'A' <uint32 n> <n float32 @16kHz> feeds audio, 'E' flushes the
/// session and answers 0x1E on stdout, 'C' drops the session. stdout carries transcript pieces as
/// they decode, plus "\u{1D}READY\n" once the model is warm.
final class VoxtralServer: @unchecked Sendable {  // state is guarded by `lock`
    static let modelDirectory = NSHomeDirectory() + "/Documents/huggingface/models/voxtral"
    private static let modelFiles = ["model-metal-int4.pte", "tekken.json", "preprocessor.pte"]

    static var serverPath: String { (Bundle.main.resourcePath ?? "") + "/voxtral-server" }

    static var isInstalled: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: serverPath)
            && modelFiles.allSatisfy { fm.fileExists(atPath: modelDirectory + "/" + $0) }
    }

    /// Called on the main thread with the full transcript of the current session.
    var onText: ((String) -> Void)?

    private var process: Process?
    private var stdinHandle: FileHandle?
    private let writeQueue = DispatchQueue(label: "voxtral.write")
    private let lock = NSLock()
    private var pending = Data()           // stdout bytes not yet assigned to a session
    private var sessionBytes = Data()      // transcript bytes of the current session
    private var ready = false
    private var readyContinuation: CheckedContinuation<Bool, Never>?
    private var finishContinuation: CheckedContinuation<String?, Never>?
    private var sessionOpen = false
    private var finishToken = 0
    // Voxtral steps in 80 ms blocks (1280 samples). Feeding other sizes makes it redo work on
    // partial blocks: measured 27% slower than real time with the mic's 1365-sample buffers.
    private static let blockSamples = 1280
    private var unsent: [Float] = []    // touched only on writeQueue

    var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return ready && process?.isRunning == true
    }

    /// Launch the server and wait until the model is loaded and warm.
    func start(timeout: TimeInterval = 90) async -> Bool {
        if isReady { return true }
        guard lock.withLock({ process == nil }), Self.isInstalled else { return false }

        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", "voxtral-server --server"]
        try? kill.run()
        kill.waitUntilExit()

        let resources = Bundle.main.resourcePath ?? ""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.serverPath)
        p.arguments = [
            "--server",
            "--model_path", Self.modelDirectory + "/model-metal-int4.pte",
            "--tokenizer_path", Self.modelDirectory + "/tekken.json",
            "--preprocessor_path", Self.modelDirectory + "/preprocessor.pte",
        ]
        // The Metal kernels embedded in the model dlopen libomp and libc++ by leaf name.
        var env = ProcessInfo.processInfo.environment
        env["DYLD_LIBRARY_PATH"] = "/usr/lib:" + resources
        p.environment = env
        // Dictation is interactive: keep the server off the throttled QoS tiers a menu bar app gets.
        switch UserDefaults.standard.string(forKey: "debugVoxtralQoS") {
        case "default": p.qualityOfService = .default
        case "userInitiated": p.qualityOfService = .userInitiated
        default: p.qualityOfService = .userInteractive
        }

        let inPipe = Pipe()
        let outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = Self.stderrLog()

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.consume(data)
        }
        p.terminationHandler = { [weak self] proc in
            NSLog("DictationApp: [VOXTRAL] server exited (status %d)", proc.terminationStatus)
            self?.handleTermination()
        }

        do {
            try p.run()
        } catch {
            NSLog("DictationApp: [VOXTRAL] failed to launch: %@", error.localizedDescription)
            return false
        }
        lock.withLock {
            process = p
            stdinHandle = inPipe.fileHandleForWriting
        }
        NSLog("DictationApp: [VOXTRAL] server launched (PID %d), loading model...", p.processIdentifier)

        let started = ProcessInfo.processInfo.systemUptime
        let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            if !armReady(cont) {
                cont.resume(returning: true)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.resolveReady(false)
            }
        }
        NSLog("DictationApp: [VOXTRAL] ready=%@ after %.1fs", ok ? "yes" : "no",
              ProcessInfo.processInfo.systemUptime - started)
        if !ok { stop() }
        return ok
    }

    func stop() {
        lock.lock()
        let p = process
        process = nil
        stdinHandle = nil
        ready = false
        lock.unlock()
        p?.terminate()
        resolveFinish(nil)
    }

    /// Start a new dictation session (clears the live transcript).
    func begin() {
        writeQueue.async { [weak self] in self?.unsent.removeAll() }
        lock.lock()
        sessionBytes = Data()
        sessionOpen = true
        lock.unlock()
    }

    /// Feed 16 kHz mono samples. Safe to call from the audio thread.
    func feed(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.unsent.append(contentsOf: samples)
            let whole = self.unsent.count / Self.blockSamples * Self.blockSamples
            guard whole > 0 else { return }
            let block = Array(self.unsent[0..<whole])
            self.unsent.removeFirst(whole)
            self.writeNow(Self.audioPacket(block))
        }
    }

    private static func audioPacket(_ samples: [Float]) -> Data {
        var packet = Data(capacity: 5 + samples.count * 4)
        packet.append(UInt8(ascii: "A"))
        var count = UInt32(samples.count).littleEndian
        withUnsafeBytes(of: &count) { packet.append(contentsOf: $0) }
        samples.withUnsafeBufferPointer { packet.append(UnsafeBufferPointer(start: $0.baseAddress, count: $0.count)) }
        return packet
    }

    /// Flush the session and return its full transcript, or nil if the server failed.
    func finish(timeout: TimeInterval = 8) async -> String? {
        guard isReady else { return nil }
        let text = await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let token = armFinish(cont)
            writeQueue.async { [weak self] in
                guard let self else { return }
                if !self.unsent.isEmpty {
                    self.writeNow(Self.audioPacket(self.unsent))
                    self.unsent.removeAll()
                }
                self.writeNow(Data([UInt8(ascii: "E")]))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.resolveFinish(nil, token: token)
            }
        }
        lock.withLock { sessionOpen = false }
        return text
    }

    /// Drop the current session without producing text.
    func cancel() {
        lock.lock()
        let wasOpen = sessionOpen
        sessionOpen = false
        lock.unlock()
        writeQueue.async { [weak self] in
            self?.unsent.removeAll()
            if wasOpen { self?.writeNow(Data([UInt8(ascii: "C")])) }
        }
    }

    // MARK: - Private

    /// Stores the readiness continuation; returns false if the server is already ready.
    private func armReady(_ cont: CheckedContinuation<Bool, Never>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if ready { return false }
        readyContinuation = cont
        return true
    }

    private func armFinish(_ cont: CheckedContinuation<String?, Never>) -> Int {
        lock.lock(); defer { lock.unlock() }
        finishToken += 1
        finishContinuation = cont
        return finishToken
    }

    /// Must run on writeQueue.
    private func writeNow(_ data: Data) {
        let handle = lock.withLock { stdinHandle }
        do {
            try handle?.write(contentsOf: data)
        } catch {
            NSLog("DictationApp: [VOXTRAL] write failed: %@", error.localizedDescription)
        }
    }

    private func consume(_ data: Data) {
        lock.lock()
        pending.append(data)
        var becameReady = false
        if !ready, let range = pending.range(of: Data("\u{1D}READY\n".utf8)) {
            ready = true
            becameReady = true
            pending.removeSubrange(pending.startIndex..<range.upperBound)
        }
        var finished: String?
        var sessionDone = false
        if ready {
            if let end = pending.firstIndex(of: 0x1E) {
                sessionBytes.append(pending[pending.startIndex..<end])
                pending.removeSubrange(pending.startIndex...end)
                finished = String(decoding: sessionBytes, as: UTF8.self)
                sessionDone = true
            } else {
                sessionBytes.append(pending)
                pending.removeAll()
            }
        }
        let live = sessionOpen && !sessionDone ? String(decoding: sessionBytes, as: UTF8.self) : nil
        lock.unlock()

        if becameReady { resolveReady(true) }
        if sessionDone { resolveFinish(finished ?? "") }
        if let live, !live.isEmpty, let onText {
            DispatchQueue.main.async { onText(live) }
        }
    }

    private func resolveReady(_ value: Bool) {
        lock.lock()
        let cont = readyContinuation
        readyContinuation = nil
        lock.unlock()
        cont?.resume(returning: value)
    }

    private func resolveFinish(_ value: String?, token: Int? = nil) {
        lock.lock()
        if let token, token != finishToken {
            lock.unlock()
            return
        }
        let cont = finishContinuation
        finishContinuation = nil
        lock.unlock()
        cont?.resume(returning: value)
    }

    private func handleTermination() {
        lock.lock()
        process = nil
        stdinHandle = nil
        ready = false
        lock.unlock()
        resolveReady(false)
        resolveFinish(nil)
    }

    private static func stderrLog() -> FileHandle {
        let dir = DictationDiagnostics.logDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("voxtral-server.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return (try? FileHandle(forWritingTo: url)) ?? FileHandle.nullDevice
    }
}

/// Drops long silences before they reach Voxtral. The model runs at roughly real time on an M1 Pro,
/// so every second of pause it does not have to process is a second less of backlog at the end.
/// Speech chunks pass through, followed by a short hangover so trailing words still finalize; the
/// last moments of silence are kept as pre-roll so the first syllable after a pause is not clipped.
final class SilenceGate {
    // Speech threshold follows the room's noise floor. A fixed 0.008 RMS cut real speech: Diego's
    // dictations measure 0.004-0.014 RMS against a 0.001-0.002 floor.
    private var noiseFloor: Float = 0.0015
    private var threshold: Float { max(0.0025, noiseFloor * 2.5) }
    private let hangoverSamples = 16_000 * 8 / 10
    private let prerollSamples = 16_000 * 3 / 10
    private var hangoverLeft = 0
    private var preroll: [Float] = []
    private(set) var droppedSamples = 0

    func process(_ chunk: [Float]) -> [Float] {
        guard !chunk.isEmpty else { return [] }
        var sum: Float = 0
        for s in chunk { sum += s * s }
        let rms = (sum / Float(chunk.count)).squareRoot()

        if rms < threshold {
            noiseFloor = noiseFloor * 0.95 + rms * 0.05
        }
        if rms >= threshold {
            hangoverLeft = hangoverSamples
            let out = preroll + chunk
            preroll.removeAll(keepingCapacity: true)
            return out
        }
        if hangoverLeft > 0 {
            hangoverLeft -= chunk.count
            return chunk
        }
        preroll.append(contentsOf: chunk)
        if preroll.count > prerollSamples {
            let excess = preroll.count - prerollSamples
            droppedSamples += excess
            preroll.removeFirst(excess)
        }
        return []
    }
}
