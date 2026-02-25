# Technical Findings

## WinForms Kills WinRT Speech Recognition

**The critical discovery**: WinRT `SpeechRecognizer` silently stops capturing audio when WinForms `Form` objects exist anywhere in the process. No errors, no exceptions — just zero hypothesis events and zero results.

### Scope of the problem

- **Process-wide**: Even invisible/minimized forms on a separate thread poison speech capture
- **Cross-process**: A parent process showing a WinForms window prevents a child process's WinRT from accessing the microphone
- **Any visible Form**: Doesn't matter if it's TopMost, has Opacity, or is a plain window — all fail
- The Windows microphone indicator in the taskbar doesn't even appear

### What doesn't cause the issue

- Loading `System.Windows.Forms.dll` assembly — safe
- Creating a hidden form (never shown) — safe
- `DoEvents()` loop — safe
- `NotifyIcon` (tray icon) — safe
- Win32 windows (`CreateWindowEx`, `HWND_MESSAGE`) — safe

### The solution

Eliminate WinForms entirely. Use pure Win32 API via P/Invoke:

| Component | WinForms (broken) | Win32 (working) |
|-----------|-------------------|-----------------|
| Message pump | `Application.DoEvents()` | `PeekMessage` / `DispatchMessage` |
| Tray icon | `NotifyIcon` + `ContextMenuStrip` | `Shell_NotifyIcon` + message-only window |
| Overlay | `Form` with `TopMost` | `CreateWindowEx` + `WS_EX_LAYERED` + GDI |
| Hotkey | `RegisterHotKey` on Form handle | `GetAsyncKeyState` polling |
| Icons | `Icon` / `Bitmap` | `CreateBitmap` + `CreateIconIndirect` |

### Other WinRT notes

- WinRT types loaded via `Type.GetType("..., ContentType=WindowsRuntime")` reflection
- Events subscribed via `Expression.Lambda` typed handler delegates
- `WindowsRuntimeSystemExtensions.AsTask` for async operation awaiting
- `StopAsync()` completes before `ResultGenerated` fires — must drain messages after stop
- WinRT internally segments long speech (hypothesis resets); detect and save segments manually
- `BabbleTimeout` defaults to ~20s — set to 5min for long dictation
