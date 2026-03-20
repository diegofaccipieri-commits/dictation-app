# DictationApp Windows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Windows system tray app that provides offline speech-to-text with auto-paste, using Tauri 2 + whisper.cpp.

**Architecture:** Tauri 2 app with Rust backend handling audio capture (cpal), transcription (whisper-rs), global hotkeys (Win32 hooks), and auto-paste (SendInput). Lightweight HTML/JS frontend for the popover window. Models downloaded on first use from HuggingFace.

**Tech Stack:** Rust, Tauri 2, whisper-rs 0.16, cpal 0.15, arboard 3, windows crate 0.58, HTML/CSS/JS

**Spec:** `docs/superpowers/specs/2026-03-20-dictation-app-windows-design.md`

---

## File Structure

```
dictation-app-windows/
├── src-tauri/
│   ├── src/
│   │   ├── main.rs            # Tauri setup, tray, commands, app state
│   │   ├── audio.rs           # Mic capture, resample to 16kHz, WAV write
│   │   ├── transcriber.rs     # whisper-rs wrapper, Small + Turbo, streaming + final
│   │   ├── hotkey.rs          # Win32 WH_KEYBOARD_LL hook, double-tap Ctrl
│   │   ├── paste.rs           # Clipboard + SendInput Ctrl+V
│   │   ├── text_cleaner.rs    # Hallucination filter, punctuation commands, capitalize
│   │   ├── models.rs          # Model download with progress, cache in %APPDATA%
│   │   └── batch.rs           # File/folder transcription with timestamps + diarization
│   ├── Cargo.toml
│   ├── tauri.conf.json
│   ├── icons/                 # App icons (ico format)
│   └── build.rs
├── src/
│   ├── index.html             # Main window
│   ├── app.js                 # Frontend logic, Tauri IPC
│   └── style.css              # Dark theme, compact layout
├── package.json
└── README.md
```

---

### Task 1: Project Scaffolding

**Files:**
- Create: `dictation-app-windows/` (entire scaffold)
- Create: `src-tauri/Cargo.toml`
- Create: `src-tauri/tauri.conf.json`
- Create: `src-tauri/src/main.rs`
- Create: `src/index.html`, `src/app.js`, `src/style.css`
- Create: `package.json`

- [ ] **Step 1: Create the project directory and initialize**

```bash
mkdir -p ~/dictation-app-windows
cd ~/dictation-app-windows
npm init -y
npm install @tauri-apps/cli@latest @tauri-apps/api@latest
npx tauri init
```

When prompted: app name "DictationApp", window title "DictationApp", dev command empty, build command empty, frontend path "../src".

- [ ] **Step 2: Set up Cargo.toml dependencies**

Edit `src-tauri/Cargo.toml` to add all dependencies:

```toml
[dependencies]
tauri = { version = "2", features = ["tray-icon"] }
tauri-plugin-updater = "2"
tauri-plugin-process = "2"
whisper-rs = "0.16"
cpal = "0.15"
arboard = "3"
hound = "3.5"          # WAV read/write
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tokio = { version = "1", features = ["full"] }
crossbeam-channel = "0.5"
reqwest = { version = "0.12", features = ["blocking", "stream"] }
dirs = "5"              # %APPDATA% path

[target.'cfg(windows)'.dependencies]
windows = { version = "0.58", features = [
    "Win32_Foundation",
    "Win32_System_LibraryLoader",
    "Win32_UI_Input_KeyboardAndMouse",
    "Win32_UI_WindowsAndMessaging",
] }
```

- [ ] **Step 3: Configure tauri.conf.json**

Key settings: `identifier: "com.diego.dictationapp"`, `productName: "DictationApp"`, system tray enabled, single window (hidden by default), updater plugin with GitHub endpoint.

- [ ] **Step 4: Create minimal frontend**

`src/index.html`: Basic HTML shell with div containers for status, transcription text, model selectors, history, batch status.

`src/style.css`: Dark theme, 360x400px window, monospace font, compact layout.

`src/app.js`: Skeleton with Tauri `invoke` and `listen` imports. Empty event handlers.

- [ ] **Step 5: Create minimal main.rs with system tray**

```rust
use tauri::{
    menu::{Menu, MenuItem, PredefinedMenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    Manager,
};

fn main() {
    tauri::Builder::default()
        .setup(|app| {
            // System tray
            let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
            let version = MenuItem::with_id(app, "version", "DictationApp v1.18", false, None::<&str>)?;
            let sep = PredefinedMenuItem::separator(app)?;
            let menu = Menu::with_items(app, &[&version, &sep, &quit])?;

            TrayIconBuilder::new()
                .tooltip("DictationApp")
                .menu(&menu)
                .menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "quit" => app.exit(0),
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up, ..
                    } = event {
                        let app = tray.app_handle();
                        if let Some(win) = app.get_webview_window("main") {
                            if win.is_visible().unwrap_or(false) {
                                let _ = win.hide();
                            } else {
                                let _ = win.show();
                                let _ = win.set_focus();
                            }
                        }
                    }
                })
                .build(app)?;
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error running app");
}
```

- [ ] **Step 6: Verify build**

```bash
cd ~/dictation-app-windows
npx tauri build --debug
```

Expected: App compiles, tray icon appears, left-click toggles window, right-click shows menu with Quit.

- [ ] **Step 7: Initialize git and commit**

```bash
cd ~/dictation-app-windows
git init
git add -A
git commit -m "Initial scaffold: Tauri 2 app with system tray"
```

---

### Task 2: Model Download and Management (models.rs)

**Files:**
- Create: `src-tauri/src/models.rs`
- Modify: `src-tauri/src/main.rs` (add module, Tauri commands)

- [ ] **Step 1: Implement models.rs**

```rust
// models.rs
use std::path::PathBuf;
use std::fs;
use std::io::Write;

const SMALL_URL: &str = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin";
const TURBO_URL: &str = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin";
const SMALL_FILE: &str = "ggml-small.bin";
const TURBO_FILE: &str = "ggml-large-v3-turbo.bin";

pub fn models_dir() -> PathBuf {
    let base = dirs::data_dir().unwrap_or_else(|| PathBuf::from("."));
    base.join("DictationApp").join("models")
}

pub fn model_path(name: &str) -> PathBuf {
    models_dir().join(match name {
        "small" => SMALL_FILE,
        "turbo" => TURBO_FILE,
        _ => SMALL_FILE,
    })
}

pub fn is_downloaded(name: &str) -> bool {
    model_path(name).exists()
}

/// Download model with progress callback. Returns path on success.
pub fn download_model(
    name: &str,
    on_progress: impl Fn(u64, u64), // (downloaded, total)
) -> Result<PathBuf, String> {
    let url = match name {
        "small" => SMALL_URL,
        "turbo" => TURBO_URL,
        _ => return Err("unknown model".into()),
    };
    let path = model_path(name);
    if path.exists() { return Ok(path); }

    fs::create_dir_all(models_dir()).map_err(|e| e.to_string())?;

    let client = reqwest::blocking::Client::new();
    let mut resp = client.get(url).send().map_err(|e| e.to_string())?;
    let total = resp.content_length().unwrap_or(0);

    let tmp = path.with_extension("tmp");
    let mut file = fs::File::create(&tmp).map_err(|e| e.to_string())?;
    let mut downloaded: u64 = 0;
    let mut buf = [0u8; 65536];

    loop {
        let n = std::io::Read::read(&mut resp, &mut buf).map_err(|e| e.to_string())?;
        if n == 0 { break; }
        file.write_all(&buf[..n]).map_err(|e| e.to_string())?;
        downloaded += n as u64;
        on_progress(downloaded, total);
    }

    fs::rename(&tmp, &path).map_err(|e| e.to_string())?;
    Ok(path)
}
```

- [ ] **Step 2: Wire into main.rs as Tauri commands**

Add `mod models;` to main.rs. Create Tauri commands `check_models` and `download_model` that emit progress events to the frontend.

- [ ] **Step 3: Test model download manually**

Run in debug mode, invoke `download_model("small")` from JS console. Verify file appears in `%APPDATA%/DictationApp/models/ggml-small.bin`.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: model download and cache management"
```

---

### Task 3: Audio Capture (audio.rs)

**Files:**
- Create: `src-tauri/src/audio.rs`
- Modify: `src-tauri/src/main.rs` (add module)

- [ ] **Step 1: Implement audio.rs**

Core functionality:
- `AudioRecorder` struct with `start()`, `stop() -> PathBuf`, `current_samples() -> Vec<f32>`
- Captures from default input device via cpal
- Converts multi-channel to mono
- Resamples to 16kHz using linear interpolation
- Accumulates samples in `Arc<Mutex<Vec<f32>>>`
- `stop()` writes WAV to temp file via `hound` crate and returns path

```rust
// Key resample function
fn resample(samples: &[f32], from_rate: u32, to_rate: u32) -> Vec<f32> {
    if from_rate == to_rate { return samples.to_vec(); }
    let ratio = from_rate as f64 / to_rate as f64;
    let out_len = (samples.len() as f64 / ratio) as usize;
    (0..out_len).map(|i| {
        let src = i as f64 * ratio;
        let idx = src as usize;
        let frac = (src - idx as f64) as f32;
        let a = samples.get(idx).copied().unwrap_or(0.0);
        let b = samples.get(idx + 1).copied().unwrap_or(a);
        a + frac * (b - a)
    }).collect()
}
```

- [ ] **Step 2: Test recording**

Create a Tauri command `test_record` that records 3 seconds, saves WAV, and returns the path. Verify the WAV is 16kHz mono via an audio player.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat: audio capture with cpal, resample to 16kHz"
```

---

### Task 4: Transcription Engine (transcriber.rs)

**Files:**
- Create: `src-tauri/src/transcriber.rs`
- Modify: `src-tauri/src/main.rs`

- [ ] **Step 1: Implement transcriber.rs**

```rust
use whisper_rs::{WhisperContext, WhisperContextParameters, FullParams, SamplingStrategy};
use std::sync::{Arc, Mutex};
use std::path::Path;

pub struct Transcriber {
    ctx: Arc<WhisperContext>,
}

impl Transcriber {
    pub fn new(model_path: &Path) -> Result<Self, String> {
        let params = WhisperContextParameters::default();
        let ctx = WhisperContext::new_with_params(
            model_path.to_str().unwrap(), params
        ).map_err(|e| format!("failed to load model: {e}"))?;
        Ok(Self { ctx: Arc::new(ctx) })
    }

    /// Transcribe f32 samples (16kHz mono). Returns text.
    pub fn transcribe_samples(&self, samples: &[f32]) -> Result<String, String> {
        let mut state = self.ctx.create_state()
            .map_err(|e| format!("state error: {e}"))?;
        let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
        params.set_language(None); // auto-detect
        params.set_no_speech_thold(0.3);

        state.full(params, samples)
            .map_err(|e| format!("transcribe error: {e}"))?;

        let n = state.full_n_segments()
            .map_err(|e| format!("segments error: {e}"))?;
        let mut text = String::new();
        for i in 0..n {
            if let Ok(seg) = state.full_get_segment_text(i) {
                text.push_str(&seg);
            }
        }
        Ok(text.trim().to_string())
    }

    /// Transcribe WAV file. Returns text.
    pub fn transcribe_file(&self, path: &Path) -> Result<String, String> {
        let samples = read_wav_16khz(path)?;
        self.transcribe_samples(&samples)
    }

    /// Transcribe WAV file returning segments with timestamps.
    pub fn transcribe_with_segments(&self, path: &Path)
        -> Result<Vec<Segment>, String>
    {
        let samples = read_wav_16khz(path)?;
        let mut state = self.ctx.create_state()
            .map_err(|e| format!("state error: {e}"))?;
        let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
        params.set_language(None);

        state.full(params, &samples)
            .map_err(|e| format!("transcribe error: {e}"))?;

        let n = state.full_n_segments()
            .map_err(|e| format!("segments error: {e}"))?;
        let mut segments = Vec::new();
        for i in 0..n {
            let text = state.full_get_segment_text(i).unwrap_or_default();
            let t0 = state.full_get_segment_t0(i).unwrap_or(0);
            let t1 = state.full_get_segment_t1(i).unwrap_or(0);
            segments.push(Segment {
                text: text.trim().to_string(),
                start: t0 as f64 / 100.0,
                end: t1 as f64 / 100.0,
            });
        }
        Ok(segments)
    }
}

#[derive(Clone, serde::Serialize)]
pub struct Segment {
    pub text: String,
    pub start: f64,
    pub end: f64,
}

fn read_wav_16khz(path: &Path) -> Result<Vec<f32>, String> {
    let mut reader = hound::WavReader::open(path)
        .map_err(|e| format!("WAV read error: {e}"))?;
    let spec = reader.spec();
    let samples: Vec<f32> = match spec.sample_format {
        hound::SampleFormat::Float => {
            reader.samples::<f32>().filter_map(|s| s.ok()).collect()
        }
        hound::SampleFormat::Int => {
            let max = (1 << (spec.bits_per_sample - 1)) as f32;
            reader.samples::<i32>().filter_map(|s| s.ok())
                .map(|s| s as f32 / max).collect()
        }
    };
    // Convert to mono if needed
    let mono = if spec.channels > 1 {
        samples.chunks(spec.channels as usize)
            .map(|ch| ch.iter().sum::<f32>() / ch.len() as f32)
            .collect()
    } else { samples };
    // Resample if needed
    Ok(crate::audio::resample(&mono, spec.sample_rate, 16000))
}
```

- [ ] **Step 2: Add TranscriberManager**

Manages Small + Turbo instances. Loads models on startup, exposes `transcribe_streaming(samples)` (Small) and `transcribe_final(path)` (Turbo). Runs on dedicated threads to avoid blocking.

- [ ] **Step 3: Wire timeout race**

Final transcription uses `crossbeam_channel::select!` with 45s timeout. If Turbo doesn't finish, return streaming fallback.

- [ ] **Step 4: Test with a sample WAV**

Record a test WAV, invoke transcription, verify output text makes sense.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: whisper-rs transcription engine with Small + Turbo"
```

---

### Task 5: Text Cleaner (text_cleaner.rs)

**Files:**
- Create: `src-tauri/src/text_cleaner.rs`

- [ ] **Step 1: Port TextCleaner from macOS**

Direct port of the Swift `TextCleaner` logic to Rust:
- `strip_whisper_tokens(text)` — remove `<|...|>` patterns
- `strip_hallucinations(text)` — remove "thank you", "obrigado", etc.
- `apply_punctuation_commands(text)` — "vírgula" → ",", "ponto final" → ".", etc.
- `capitalize_after_sentence_end(text)`
- `clean(text) -> String` — applies all in order

- [ ] **Step 2: Commit**

```bash
git add -A
git commit -m "feat: text cleaner (hallucinations, punctuation, capitalization)"
```

---

### Task 6: Hotkey Monitor (hotkey.rs)

**Files:**
- Create: `src-tauri/src/hotkey.rs`

- [ ] **Step 1: Implement Win32 keyboard hook**

```rust
// hotkey.rs — runs on dedicated thread with Win32 message pump
// Detects double-tap Ctrl (VK_LCONTROL or VK_RCONTROL) within 500ms
// During recording: single Ctrl tap stops
// ESC cancels recording
// Sends events via crossbeam channel to main app logic
```

Key implementation:
- `start(tx: Sender<HotkeyEvent>)` spawns thread, installs `WH_KEYBOARD_LL` hook, runs message pump
- `HotkeyEvent` enum: `DoubleTapCtrl`, `Escape`
- Track `last_ctrl_press_time` and `ctrl_is_down` in thread-local static
- Single tap while recording = stop (communicated via `is_recording` AtomicBool)

- [ ] **Step 2: Test hotkey detection**

Run app, press Ctrl Ctrl quickly, verify event fires. Press ESC, verify cancel event.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat: global hotkey monitor (double-tap Ctrl + ESC)"
```

---

### Task 7: Auto-Paste (paste.rs)

**Files:**
- Create: `src-tauri/src/paste.rs`

- [ ] **Step 1: Implement clipboard + SendInput**

```rust
use arboard::Clipboard;

pub fn copy_and_paste(text: &str) -> Result<(), String> {
    let mut cb = Clipboard::new().map_err(|e| e.to_string())?;
    cb.set_text(text).map_err(|e| e.to_string())?;

    // Small delay for clipboard to settle
    std::thread::sleep(std::time::Duration::from_millis(100));

    simulate_ctrl_v();
    Ok(())
}

fn simulate_ctrl_v() {
    // Win32 SendInput: Ctrl down, V down, V up, Ctrl up (batched)
    // See Task 6 research for exact implementation
}
```

- [ ] **Step 2: Test paste into Notepad**

Open Notepad, invoke paste command, verify text appears.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat: clipboard copy + auto-paste via SendInput"
```

---

### Task 8: Main App Logic (main.rs integration)

**Files:**
- Modify: `src-tauri/src/main.rs` (wire everything together)

- [ ] **Step 1: Create AppState**

```rust
struct AppState {
    recorder: Mutex<AudioRecorder>,
    streaming_model: Mutex<Option<Transcriber>>,  // Small
    final_model: Mutex<Option<Transcriber>>,       // Turbo
    recording_state: AtomicU8,  // 0=idle, 1=recording, 2=transcribing
    committed_text: Mutex<String>,
    history: Mutex<Vec<String>>,
}
```

- [ ] **Step 2: Wire hotkey events to recording flow**

Hotkey `DoubleTapCtrl` → if idle: start recording + streaming loop. If recording: stop → final transcription → paste.

- [ ] **Step 3: Implement streaming loop**

Spawn thread that every 2s grabs `current_samples()`, transcribes with Small, emits `streaming-update` event to frontend.

- [ ] **Step 4: Implement final transcription with timeout**

On stop: Turbo transcribes full WAV on thread. Race with 45s timeout. Apply text_cleaner. Copy + paste. Emit `transcription-complete` event.

- [ ] **Step 5: Wire tray menu items**

Start/Stop Recording, Transcrever Arquivo, Transcrever Pasta, Check for Updates, Quit.

- [ ] **Step 6: Test full dictation flow**

Ctrl Ctrl → speak → Ctrl → text appears in focused app.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: complete dictation flow (record, transcribe, paste)"
```

---

### Task 9: Batch Transcription (batch.rs)

**Files:**
- Create: `src-tauri/src/batch.rs`

- [ ] **Step 1: Implement single file transcription**

Uses `transcriber.transcribe_with_segments()`. Generates .txt with:
- Header: filename, duration, date
- Timestamped segments: `[00:00.0 - 00:05.2] text`
- Speaker diarization: >2s gap between segments = speaker switch

- [ ] **Step 2: Implement folder batch**

Iterate supported files (wav, mp3, m4a, mp4, mov, webm, ogg), transcribe each, write .txt next to source. Emit progress events.

- [ ] **Step 3: Wire to tray menu + file dialogs**

Tray "Transcrever Arquivo" → native file picker → batch single.
Tray "Transcrever Pasta" → native folder picker → batch all.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: batch transcription with timestamps and diarization"
```

---

### Task 10: Frontend UI (index.html, app.js, style.css)

**Files:**
- Modify: `src/index.html`, `src/app.js`, `src/style.css`

- [ ] **Step 1: Build the popover UI**

Layout (dark theme, 360x400px):
- Status bar: "Ready (Small)" / "Recording..." / "Transcribing (Turbo)..."
- Transcription text area (scrollable, selectable)
- Model selector row: Live [Small|Turbo] — Batch [Small|Turbo]
- History list (last 5 items, click to re-paste)
- Batch progress bar (when running)
- Footer: version + "Ctrl Ctrl to dictate"

- [ ] **Step 2: Wire Tauri events**

Listen to: `streaming-update`, `transcription-complete`, `state-change`, `batch-progress`, `model-loading`.
Invoke: `set_live_model`, `set_batch_model`, `reuse_history_item`.

- [ ] **Step 3: Model download UI**

On first launch, show download progress bar per model. Block recording until Small is ready.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: popover UI with status, history, model selectors"
```

---

### Task 11: Auto-Update (updater.rs)

**Files:**
- Modify: `src-tauri/tauri.conf.json` (updater config)
- Modify: `src/app.js` (update check from JS)

- [ ] **Step 1: Configure tauri-plugin-updater**

Generate signing keys: `npx tauri signer generate -w ~/.tauri/dictation-app-windows.key`

Add to `tauri.conf.json`:
```json
{
  "plugins": {
    "updater": {
      "endpoints": [
        "https://github.com/diegofaccipieri-commits/dictation-app-windows/releases/latest/download/latest.json"
      ]
    }
  }
}
```

- [ ] **Step 2: Add update check on launch + menu item**

JS: on load, call `check()` from `@tauri-apps/plugin-updater`. If update available, show prompt. Menu "Check for Updates" triggers manual check.

- [ ] **Step 3: Anti-loop guard**

Store last checked version in localStorage. Skip auto-check if version matches (same pattern as macOS).

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: auto-update via GitHub releases"
```

---

### Task 12: Build, Test, and Release

- [ ] **Step 1: Full build**

```bash
npx tauri build
```

Produces .msi installer in `src-tauri/target/release/bundle/msi/`.

- [ ] **Step 2: End-to-end test on Windows**

1. Install .msi
2. App appears in system tray
3. First launch downloads models (progress shown)
4. Ctrl Ctrl → record → Ctrl → text pasted into Notepad
5. Right-click → Transcrever Arquivo → select WAV → .txt generated
6. Model switching works (Small ↔ Turbo)
7. History re-paste works

- [ ] **Step 3: Create GitHub repo and first release**

```bash
gh repo create diegofaccipieri-commits/dictation-app-windows --public
git remote add origin https://github.com/diegofaccipieri-commits/dictation-app-windows.git
git push -u origin main
gh release create v1.0 src-tauri/target/release/bundle/msi/*.msi --title "DictationApp Windows v1.0"
```

- [ ] **Step 4: Final commit**

```bash
git add -A
git commit -m "v1.0: initial Windows release"
```
