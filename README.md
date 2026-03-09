# DictationApp

A macOS menu bar app for local multilingual dictation (PT/EN/ES) using WhisperKit.

## Build

1. Open `DictationApp.xcodeproj` in Xcode 15+
2. Wait for Swift packages to resolve (WhisperKit + KeyboardShortcuts)
3. Select the `DictationApp` scheme, target "My Mac"
4. Press Cmd+R to run

## First Run

- Grant microphone access when prompted
- WhisperKit downloads the `whisper-small` model on first use (~500MB)
- Model is cached at `~/Library/Containers/com.diego.dictationapp/`

## Usage

- **Cmd+Shift+Space** — toggle dictation from any app
- Or click the 🎤 icon in the menu bar
- Transcribed text appears in the popover and is automatically copied to clipboard

## Notes

- Fully offline after first model download
- Supports PT, EN, ES and mixed-language dictation without configuration
