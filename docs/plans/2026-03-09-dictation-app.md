# Dictation App Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a macOS menu bar app that records voice input, transcribes it locally with WhisperKit (multilingual PT/EN/ES), and copies the result to clipboard.

**Architecture:** SwiftUI macOS app with no dock icon, living in the menu bar. AVAudioEngine captures audio when toggled. WhisperKit transcribes the recorded audio file locally. A global keyboard shortcut (Cmd+Shift+Space) and a button in the popover both toggle recording.

**Tech Stack:** Swift 5.9+, SwiftUI, WhisperKit, KeyboardShortcuts (sindresorhus), AVFoundation, NSPasteboard, NSStatusItem

---

## Prerequisites

- Xcode 15+ installed
- macOS 14+ (Sonoma) target
- Internet connection for first WhisperKit model download (~500MB, one-time)

---

### Task 1: Create Xcode Project

**Files:**
- Create: `DictationApp.xcodeproj` at `/Users/diegofaccipieri/dictation-app/`

**Step 1: Create new Xcode project**

Open Xcode → New Project → macOS → App
- Product Name: `DictationApp`
- Team: Personal Team (or your dev account)
- Bundle ID: `com.diego.dictationapp`
- Interface: SwiftUI
- Language: Swift
- Uncheck "Include Tests" for now
- Save to: `/Users/diegofaccipieri/dictation-app/`

**Step 2: Remove default window setup**

In `DictationApp.swift`, replace all content with:

```swift
import SwiftUI

@main
struct DictationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
```

**Step 3: In Info.plist, add key to hide dock icon**

Add to `Info.plist`:
```xml
<key>LSUIElement</key>
<true/>
```

In Xcode: select `DictationApp` target → Info tab → add row `Application is agent (UIElement)` = `YES`

**Step 4: Add Swift packages**

In Xcode → File → Add Package Dependencies:
- `https://github.com/argmaxinc/WhisperKit` → Up to Next Major: 0.9.0
- `https://github.com/sindresorhus/KeyboardShortcuts` → Up to Next Major: 2.0.0

**Step 5: Add microphone permission to Info.plist**

Add key: `NSMicrophoneUsageDescription`
Value: `"DictationApp needs microphone access to record your voice."`

**Step 6: Build and confirm empty app compiles**

`Cmd+B` in Xcode. Expected: Build Succeeded, no dock icon visible.

**Step 7: Commit**

```bash
cd /Users/diegofaccipieri/dictation-app
git init
git add .
git commit -m "feat: initial Xcode project with SwiftUI, WhisperKit, KeyboardShortcuts"
```

---

### Task 2: AppDelegate + Menu Bar Icon

**Files:**
- Create: `DictationApp/AppDelegate.swift`

**Step 1: Create AppDelegate.swift**

```swift
import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Dictation")
            button.action = #selector(togglePopover)
            button.target = self
        }

        let contentView = ContentView()
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 240)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: contentView)
        self.popover = popover
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover?.isShown == true {
            popover?.performClose(nil)
        } else {
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
```

**Step 2: Create placeholder ContentView.swift**

```swift
import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack {
            Text("DictationApp")
                .font(.headline)
            Text("Ready")
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(width: 360, height: 240)
    }
}
```

**Step 3: Build and run**

`Cmd+R`. Expected: mic icon appears in menu bar. Click it → popover opens with "DictationApp / Ready".

**Step 4: Commit**

```bash
git add .
git commit -m "feat: menu bar icon and popover skeleton"
```

---

### Task 3: RecordingState + AudioRecorder

**Files:**
- Create: `DictationApp/RecordingState.swift`
- Create: `DictationApp/AudioRecorder.swift`

**Step 1: Create RecordingState.swift**

```swift
import Foundation

enum RecordingState {
    case idle
    case recording
    case transcribing
}
```

**Step 2: Create AudioRecorder.swift**

```swift
import AVFoundation
import Foundation

class AudioRecorder: NSObject, ObservableObject {
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private(set) var recordingURL: URL?

    var onRecordingFinished: ((URL) -> Void)?

    func startRecording() throws {
        let engine = AVAudioEngine()
        audioEngine = engine

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        recordingURL = tempURL

        audioFile = try AVAudioFile(forWriting: tempURL, settings: format.settings)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            try? self?.audioFile?.write(from: buffer)
        }

        try engine.start()
    }

    func stopRecording() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioFile = nil

        if let url = recordingURL {
            onRecordingFinished?(url)
        }
    }
}
```

**Step 3: Build to verify no compile errors**

`Cmd+B`. Expected: Build Succeeded.

**Step 4: Commit**

```bash
git add .
git commit -m "feat: AudioRecorder with AVAudioEngine"
```

---

### Task 4: WhisperKit Transcription Manager

**Files:**
- Create: `DictationApp/TranscriptionManager.swift`

**Step 1: Create TranscriptionManager.swift**

```swift
import WhisperKit
import Foundation

@MainActor
class TranscriptionManager: ObservableObject {
    private var whisperKit: WhisperKit?

    func loadModel() async throws {
        whisperKit = try await WhisperKit(model: "openai/whisper-small")
    }

    func transcribe(url: URL) async throws -> String {
        guard let whisperKit else { throw TranscriptionError.notLoaded }

        let results = try await whisperKit.transcribe(audioPath: url.path)
        return results.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}

enum TranscriptionError: Error {
    case notLoaded
}
```

**Step 2: Build to verify no compile errors**

`Cmd+B`. Expected: Build Succeeded.

**Step 3: Commit**

```bash
git add .
git commit -m "feat: TranscriptionManager with WhisperKit"
```

---

### Task 5: DictationViewModel — Wiring Everything Together

**Files:**
- Create: `DictationApp/DictationViewModel.swift`

**Step 1: Create DictationViewModel.swift**

```swift
import SwiftUI
import AppKit

@MainActor
class DictationViewModel: ObservableObject {
    @Published var state: RecordingState = .idle
    @Published var transcribedText: String = ""
    @Published var errorMessage: String? = nil

    private let recorder = AudioRecorder()
    private let transcriptionManager = TranscriptionManager()

    init() {
        recorder.onRecordingFinished = { [weak self] url in
            Task { await self?.transcribe(url: url) }
        }
        Task { await self?.loadModel() }
    }

    private func loadModel() async {
        do {
            try await transcriptionManager.loadModel()
        } catch {
            errorMessage = "Failed to load model: \(error.localizedDescription)"
        }
    }

    func toggle() {
        switch state {
        case .idle:
            startRecording()
        case .recording:
            stopRecording()
        case .transcribing:
            break // ignore taps while transcribing
        }
    }

    private func startRecording() {
        do {
            try recorder.startRecording()
            state = .recording
            errorMessage = nil
        } catch {
            errorMessage = "Microphone error: \(error.localizedDescription)"
        }
    }

    private func stopRecording() {
        state = .transcribing
        recorder.stopRecording()
    }

    private func transcribe(url: URL) async {
        do {
            let text = try await transcriptionManager.transcribe(url: url)
            transcribedText = text
            copyToClipboard(text)
            state = .idle
        } catch {
            errorMessage = "Transcription failed: \(error.localizedDescription)"
            state = .idle
        }
        try? FileManager.default.removeItem(at: url) // clean up temp file
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
```

**Step 2: Build to verify no compile errors**

`Cmd+B`. Expected: Build Succeeded.

**Step 3: Commit**

```bash
git add .
git commit -m "feat: DictationViewModel wiring recorder and transcription"
```

---

### Task 6: ContentView — Full UI

**Files:**
- Modify: `DictationApp/ContentView.swift`

**Step 1: Replace ContentView.swift**

```swift
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = DictationViewModel()

    var body: some View {
        VStack(spacing: 16) {
            // Status text
            Text(statusText)
                .font(.subheadline)
                .foregroundColor(statusColor)
                .animation(.easeInOut, value: viewModel.state)

            // Transcribed text area
            ScrollView {
                Text(viewModel.transcribedText.isEmpty ? "Transcription will appear here..." : viewModel.transcribedText)
                    .font(.body)
                    .foregroundColor(viewModel.transcribedText.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 100)
            .padding(8)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(8)

            // Record button
            Button(action: viewModel.toggle) {
                HStack {
                    Image(systemName: buttonIcon)
                    Text(buttonLabel)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(buttonColor)
            .disabled(viewModel.state == .transcribing)
            .keyboardShortcut(.space, modifiers: [])

            // Error message
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            // Shortcut hint
            Text("Global shortcut: ⌘⇧Space")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(width: 360, height: 260)
    }

    private var statusText: String {
        switch viewModel.state {
        case .idle: return "Ready"
        case .recording: return "Recording..."
        case .transcribing: return "Transcribing..."
        }
    }

    private var statusColor: Color {
        switch viewModel.state {
        case .idle: return .secondary
        case .recording: return .red
        case .transcribing: return .orange
        }
    }

    private var buttonIcon: String {
        switch viewModel.state {
        case .idle: return "mic.fill"
        case .recording: return "stop.fill"
        case .transcribing: return "ellipsis"
        }
    }

    private var buttonLabel: String {
        switch viewModel.state {
        case .idle: return "Start Dictation"
        case .recording: return "Stop"
        case .transcribing: return "Transcribing..."
        }
    }

    private var buttonColor: Color {
        viewModel.state == .recording ? .red : .accentColor
    }
}
```

**Step 2: Build and run**

`Cmd+R`. Click menu bar icon. Expected: popover with full UI, "Start Dictation" button visible.

**Step 3: Commit**

```bash
git add .
git commit -m "feat: full ContentView UI with recording states"
```

---

### Task 7: Menu Bar Icon State + Global Hotkey

**Files:**
- Modify: `DictationApp/AppDelegate.swift`
- Create: `DictationApp/HotkeyManager.swift`

**Step 1: Create HotkeyManager.swift**

```swift
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleDictation = Self("toggleDictation", default: .init(.space, modifiers: [.command, .shift]))
}
```

**Step 2: Update AppDelegate.swift to wire shared ViewModel + hotkey**

Replace full content of `AppDelegate.swift`:

```swift
import AppKit
import SwiftUI
import KeyboardShortcuts

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    let viewModel = DictationViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupHotkey()
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Dictation")
            button.action = #selector(togglePopover)
            button.target = self
        }

        let contentView = ContentView(viewModel: viewModel)
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 260)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: contentView)
        self.popover = popover

        // Update icon based on state
        viewModel.$state.sink { [weak self] state in
            DispatchQueue.main.async {
                let iconName = state == .recording ? "mic.fill" : "mic"
                self?.statusItem?.button?.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "Dictation")
                self?.statusItem?.button?.contentTintColor = state == .recording ? .systemRed : nil
            }
        }.store(in: &cancellables)
    }

    var cancellables = Set<AnyCancellable>()

    func setupHotkey() {
        KeyboardShortcuts.onKeyUp(for: .toggleDictation) { [weak self] in
            self?.viewModel.toggle()
        }
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover?.isShown == true {
            popover?.performClose(nil)
        } else {
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
```

**Step 3: Update ContentView to accept injected ViewModel**

In `ContentView.swift`, change the first line of `ContentView`:

```swift
// Replace:
@StateObject private var viewModel = DictationViewModel()

// With:
@ObservedObject var viewModel: DictationViewModel
```

**Step 4: Add import Combine to AppDelegate.swift**

Add at top: `import Combine`

**Step 5: Build and run**

`Cmd+R`. Expected:
- App in menu bar
- `Cmd+Shift+Space` from any app toggles recording
- Menu bar icon turns red + filled when recording
- After speaking, text appears in popover and is copied to clipboard

**Step 6: Commit**

```bash
git add .
git commit -m "feat: global hotkey Cmd+Shift+Space and dynamic menu bar icon"
```

---

### Task 8: End-to-End Smoke Test

**Step 1: Run the app**

`Cmd+R`

**Step 2: Grant microphone permission**

First launch will prompt for microphone access. Click "Allow".

**Step 3: Test dictation**

1. Press `Cmd+Shift+Space` — icon turns red
2. Say "Hello, how are you? Eu estou bem. Hola, como estas?"
3. Press `Cmd+Shift+Space` again — icon returns to normal, "Transcribing..." shows briefly
4. Text appears in popover
5. Open TextEdit → `Cmd+V` → text should paste

**Step 4: Test error states**

- Try toggling while transcribing → should be ignored (no crash)
- Check console for any model loading errors

**Step 5: Commit final state**

```bash
git add .
git commit -m "feat: dictation app complete - local Whisper multilingual PT/EN/ES"
```

---

## Known Limitations / Next Steps

- First launch downloads WhisperKit model (~500MB) — add a loading indicator for this in a future iteration
- No settings UI for changing shortcut — can be added later
- iOS version deferred — architecture supports it (ViewModel is platform-agnostic)
