# DictationApp Windows — Design Spec

## Overview

Standalone Windows port of DictationApp. Offline speech-to-text with auto-paste, system tray integration, batch transcription, and auto-update. Separate codebase from the macOS version.

**Stack:** Tauri 2 (Rust backend + HTML/CSS/JS frontend) + whisper.cpp (via whisper-rs)

**Target:** Windows 10/11, machines without dedicated GPU (CPU-only inference via AVX2/SSE)

**Language:** Portuguese (BR) UI. Multilingual transcription (PT/EN/ES auto-detect).

## Architecture

```
dictation-app-windows/
├── src-tauri/
│   ├── src/
│   │   ├── main.rs           # Tauri entry point, app setup, tray, commands
│   │   ├── audio.rs          # Mic capture via cpal, resample to 16kHz, WAV output
│   │   ├── transcriber.rs    # whisper-rs wrapper, Small + Turbo models, streaming + final
│   │   ├── hotkey.rs         # Win32 low-level keyboard hook, double-tap Ctrl detection
│   │   ├── paste.rs          # Clipboard (arboard) + SendInput Ctrl+V
│   │   ├── batch.rs          # File/folder transcription with timestamps + speaker diarization
│   │   ├── text_cleaner.rs   # Hallucination filter, punctuation commands, auto-capitalize
│   │   ├── updater.rs        # Auto-update via tauri-plugin-updater (GitHub releases)
│   │   └── models.rs         # Model download, cache management (%APPDATA%)
│   ├── Cargo.toml
│   └── tauri.conf.json
├── src/                      # Frontend
│   ├── index.html
│   ├── app.js
│   └── style.css
└── package.json
```

## Components

### audio.rs — Audio Capture
- Uses `cpal` crate for cross-platform audio input
- Captures from default input device at native sample rate
- Resamples to 16kHz mono (whisper.cpp requirement) using linear interpolation
- Accumulates samples in memory for streaming loop
- Writes final WAV to temp file for final transcription
- Exposes: `start_recording()`, `stop_recording() -> PathBuf`, `current_samples() -> (Vec<f32>, f64)`

### transcriber.rs — Whisper Engine
- Uses `whisper-rs` crate (Rust binding for whisper.cpp)
- Two model instances loaded independently:
  - **Small** (`ggml-small.bin`, ~466MB) — streaming preview during recording
  - **Turbo** (`ggml-large-v3-turbo.bin`, ~1.5GB) — final transcription + batch
- Models downloaded on first use to `%APPDATA%/DictationApp/models/`
- Transcription runs on dedicated thread (not async — whisper.cpp is blocking)
- Race timeout: 45s via `crossbeam::channel` or `tokio::select!`; falls back to streaming preview
- DecodingOptions: task=transcribe, language=auto-detect, temperature=0.0, no_speech_threshold=0.3

### hotkey.rs — Global Hotkey
- Win32 `SetWindowsHookEx(WH_KEYBOARD_LL)` for system-wide key monitoring
- Detects double-tap Ctrl (left or right) within 500ms interval
- During recording: single Ctrl tap stops recording
- ESC cancels recording
- Runs on dedicated thread with Windows message pump

### paste.rs — Auto-Paste
- Copies text to clipboard via `arboard` crate
- Simulates Ctrl+V via Win32 `SendInput` after 100ms delay
- Same flow as macOS version

### batch.rs — Batch Transcription
- Single file or entire folder transcription
- Uses Turbo model
- Generates .txt output with:
  - Metadata header (file name, duration, date)
  - Timestamps per segment
  - Speaker diarization (pause-based, >2s = speaker switch, "Falante A"/"Falante B")
- Progress reported to frontend via Tauri events
- Supported formats: wav, mp3, m4a, mp4, mov, webm, ogg

### text_cleaner.rs — Text Processing (ported from macOS)
- Strip whisper tokens (`<|...|>`)
- Remove hallucinations: "thank you", "obrigado", "thanks for watching", etc.
- Punctuation commands: "vírgula" → ",", "ponto final" → ".", etc. (PT + EN)
- Auto-capitalize after sentence-ending punctuation
- Identical behavior to macOS TextCleaner

### models.rs — Model Management
- Check `%APPDATA%/DictationApp/models/` for cached models
- Download from HuggingFace if missing (with progress callback to UI)
- Verify file integrity (file size check)
- Models: downloaded as GGML format files from huggingface.co/ggerganov/whisper.cpp

### updater.rs — Auto-Update
- Uses `tauri-plugin-updater`
- Checks GitHub releases on launch (silent) and from menu (user-initiated)
- Downloads .msi, installs, relaunches
- Anti-loop guard (same as macOS v1.18 fix)

## UI (System Tray + Window)

### System Tray
- Microphone icon (changes to red when recording)
- Left-click: toggle popover window
- Right-click: context menu
  - DictationApp vX.XX (disabled, info)
  - Start/Stop Recording
  - Transcrever Arquivo...
  - Transcrever Pasta...
  - Check for Updates...
  - Quit

### Popover Window (small, near tray)
- Status: "Ready" / "Recording..." / "Transcribing..."
- Transcription text box (selectable, scrollable)
- Model selector: Small | Turbo (for live dictation)
- Model selector: Small | Turbo (for batch/documents)
- Recent history (last 5, clickable to re-paste)
- Batch status (when running)
- Version + shortcut hint ("Ctrl Ctrl to dictate")

## Live Dictation Flow

1. Double-tap Ctrl → hotkey.rs detects → start_recording()
2. audio.rs captures mic, resamples to 16kHz, accumulates samples
3. Streaming loop (every 2s): Small model transcribes pending samples → preview in UI
4. Committed chunks (7s) locked in; preview shows tail
5. Double-tap Ctrl again (or single tap while recording) → stop_recording()
6. Final transcription: Turbo model transcribes full WAV file
7. Race with 45s timeout — if Turbo doesn't finish, use streaming fallback
8. text_cleaner processes result
9. paste.rs: clipboard + Ctrl+V into focused app
10. Return to idle

## Models

| Name | File | Size | Use |
|------|------|------|-----|
| Small | ggml-small.bin | ~466MB | Streaming preview |
| Turbo | ggml-large-v3-turbo.bin | ~1.5GB | Final transcription + batch |

Both downloaded on first launch with progress bar.

## Distribution

- Build produces .msi installer via `tauri build`
- GitHub releases for auto-update
- Repo: `diegofaccipieri-commits/dictation-app-windows`

## Non-Goals

- No wake word detection
- No HD/large-v3 model (removed)
- No macOS code sharing — fully independent codebase
- No GPU/CUDA support (CPU-only, machines don't have dedicated GPUs)
