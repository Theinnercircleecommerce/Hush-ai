# Hush

Hush is a privacy-first, menu bar voice-to-text dictation tool for macOS. It uses your own microphone and the fast Groq API (with Whisper large-v3) for transcription, optionally cleaning up filler words using Llama 3.1. Finally, it automatically pastes the transcription into whatever app you were using.

## Features
- **Menu Bar Native**: Runs quietly in the background.
- **Floating HUD**: Shows a dynamic waveform while you are speaking.
- **Global Hotkey**: Press `Shift+A` (or your custom shortcut) to start and stop dictation.
- **Privacy First**: Everything is saved locally via SwiftData.
- **Dashboard**: View your history, how many words you've transcribed, and time saved.
- **AI Cleanup**: Automatically strips "ums" and "ahs" from the text without losing the original meaning.

## Requirements
- macOS 14.0+ (Sonoma) or newer
- Apple Silicon (M1/M2/M3) recommended for performance
- A free [Groq API Key](https://console.groq.com/keys)

## Permissions Needed
Hush will prompt you for two essential permissions on first launch:
1. **Microphone**: Needed to capture your dictation.
2. **Accessibility**: Needed to automatically paste the transcribed text into your active app (using `Cmd+V`). You can enable this in *System Settings > Privacy & Security > Accessibility*.

## Setup & Building from Xcode
1. **Install Xcode**: Ensure you have Xcode 15 or newer installed from the Mac App Store.
2. **Open the Project**: Open `Hush.xcodeproj`.
3. **Build & Run**: Select your Mac as the destination and click Play (or `Cmd+R`).
4. **Export App Bundle**: To share with friends, go to `Product > Archive` in Xcode, then Distribute App.

*(Note: The `project.yml` file and `xcodegen` are used to generate the `.xcodeproj` file. The project uses KeyboardShortcuts as a dependency.)*

## Usage
1. Click the microphone icon in your menu bar.
2. Select "Settings" to input your Groq API Key.
3. Grant the required Microphone and Accessibility permissions in the Onboarding screen.
4. Press `Shift+A` to begin dictating!
