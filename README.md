# WinWhisper

Push-to-talk voice dictation for Windows 11. Built for developers using AI coding agents (Claude Code, OpenCode, Codex CLI) in Windows Terminal / WSL2.

Uses Windows 11's built-in cloud speech recognition — same quality as Win+H Voice Typing — but with full programmatic control: hotkey start, hotkey stop, no silence timeout, direct text capture.

**One file. Zero dependencies beyond stock Windows 11.**

## Why

Windows 11 Voice Typing (Win+H) has great accuracy but terrible developer UX:

- No real push-to-talk hotkey (click-based UI)
- Auto-stops after ~5s of silence (thinking pauses kill it)
- No auto-Enter after dictation (needed for terminal agents)
- No programmatic text capture
- Toolbar covers content

WinWhisper fixes all of this.

## How It Works

```
Press hotkey (default: Numpad+)
  → Starts listening, overlay shows "Listening..."
  → Speak — pause as long as you want, no timeout
  → Press hotkey again
  → Text typed into focused field via SendInput
  → Optionally sends Enter after configurable delay
```

## Requirements

- Windows 11
- "Online speech recognition" enabled: `Settings → Privacy & security → Speech → Online speech recognition`
- That's it. No installs, no API keys, no admin rights.

## Quick Start

```powershell
# Download and run (Windows PowerShell 5.1)
powershell.exe -ExecutionPolicy Bypass -File winwhisper.ps1
```

The tool runs in the system tray. Right-click the tray icon for settings, copy last transcription, or exit.

## Configuration

Settings are stored in `%APPDATA%\WinWhisper\settings.json` and can be changed via the tray icon context menu.

| Setting | Default | Description |
|---|---|---|
| Hotkey | `Numpad+` | Push-to-talk toggle key |
| Language | System default | `en-US`, `de-DE`, etc. |
| Auto-Enter | Off | Send Enter after dictation |
| Auto-Enter Delay | 800ms | Delay before sending Enter |
| Double-press | On (400ms) | Double-tap hotkey = dictate + Enter |
| Overlay | On | Show listening indicator near tray |

## CLI Flags

```
winwhisper.ps1                  # Normal launch (tray mode)
winwhisper.ps1 -Debug           # Console window + verbose logging
winwhisper.ps1 -Fallback        # Force Win+H fallback engine
winwhisper.ps1 -Settings        # Open settings dialog immediately
winwhisper.ps1 -Uninstall       # Remove autostart + settings
winwhisper.ps1 -TestSpeech      # Run speech test and exit
```

## Development

Developed on WSL/Linux, runs on Windows. See [PD.md](PD.md) for full architecture and implementation details.

### Testing from WSL

```bash
# Must use powershell.exe (5.1), NOT pwsh.exe (7+)
powershell.exe -ExecutionPolicy Bypass -File "$(wslpath -w ./test-speech.ps1)"

# With German
powershell.exe -ExecutionPolicy Bypass -File "$(wslpath -w ./test-speech.ps1)" -Language "de-DE"
```

### Technical Stack

| Component | Technology |
|---|---|
| Language | PowerShell 5.1 (Windows PowerShell) |
| Speech | `Windows.Media.SpeechRecognition` (WinRT/UWP) |
| WinRT Async | Reflection-based `AsTask` via `System.Runtime.WindowsRuntime` |
| UI | `System.Windows.Forms` (tray icon, overlay) |
| Win32 | P/Invoke (`RegisterHotKey`, `SendInput`) |
| Settings | JSON (`ConvertTo-Json` / `ConvertFrom-Json`) |

### Key Architecture Decision

The PD.md originally proposed a C# bridge via `Add-Type -ReferencedAssemblies *.winmd`. Empirical testing on Windows 11 proved this **does not work** — .winmd files can't be used as `Add-Type` references (HRESULT 0x80131047).

Instead, the working approach is **pure PowerShell** with reflection-based async helpers that resolve `AsTask` overloads from `System.WindowsRuntimeSystemExtensions` at runtime. WinRT events are wired directly via `Register-ObjectEvent`.

## License

MIT
