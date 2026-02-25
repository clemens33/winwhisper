# WinWhisper

Push-to-talk voice dictation for Windows 11. Press a hotkey, speak, press again — text gets typed into the focused window.

Uses Windows 11's built-in cloud speech recognition (same quality as Win+H Voice Typing) with full programmatic control.

**Single C# file. Pure Win32 API. Zero dependencies beyond stock Windows 11.**

## Requirements

- Windows 11
- .NET Framework 4.8 (pre-installed on Windows 11)
- "Online speech recognition" enabled: `Settings > Privacy & security > Speech > Online speech recognition`

## Build

```bash
dotnet build
```

Or with raw csc.exe (no SDK needed):

```powershell
& "$env:windir\Microsoft.NET\Framework64\v4.0.30319\csc.exe" `
  /target:exe /out:WinWhisper.exe `
  /reference:System.Runtime.WindowsRuntime.dll `
  /reference:Microsoft.CSharp.dll `
  /reference:System.Core.dll `
  WinWhisper.cs
```

## Usage

```
WinWhisper.exe           # Run (tray icon, no console)
WinWhisper.exe -debug    # Run with console logging
```

- **Shift + =** (the `+` key) or **Numpad +** — toggle recording
- Speak — live transcription shown in overlay
- Press hotkey again — text typed into focused window via SendInput
- Right-click tray icon — Exit

Logs are written to `%TEMP%\winwhisper.log`.

## Architecture

Single compiled `.exe`, single thread, no WinForms:

- **Speech**: WinRT `SpeechRecognizer` via reflection (cloud dictation)
- **Tray icon**: Win32 `Shell_NotifyIcon` (gray = idle, red = recording)
- **Overlay**: Win32 `CreateWindowEx` + GDI painting (live hypothesis text)
- **Hotkey**: `GetAsyncKeyState` polling
- **Text output**: `SendInput` with `KEYEVENTF_UNICODE`
- **Message pump**: `PeekMessage` / `DispatchMessage`

WinForms is intentionally excluded — `Form` objects silently kill WinRT speech capture. See [docs/FINDINGS.md](docs/FINDINGS.md).

## License

MIT
