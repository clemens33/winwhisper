# WinWhisper — What Worked and What Didn't

## The Goal
Build a single-exe push-to-talk voice dictation tool for Windows 11 using WinRT SpeechRecognizer (cloud quality), with a system tray icon, overlay popup, global hotkey, and SendInput text output.

## The Critical Discovery: WinForms Kills WinRT Speech

**This was the hardest bug to find.** WinRT `SpeechRecognizer` silently stops capturing audio — no errors, no exceptions, just zero hypothesis events and zero results — when WinForms `Form` objects exist in the process.

### What we tried (and failed)

1. **PowerShell + child engine.exe (v0.1–v0.2)** — Engine worked perfectly in isolation (`test-engine.ps1`), but failed in the full app. We spent many iterations debugging IPC, async stop ordering, version mismatches, stale processes — none were the real issue.

2. **Replaced `Application.Run()` with `DoEvents()` loop** — Theory: `Application.Run()` was blocking WinRT. Reality: didn't help. The overlay was still shown during recording.

3. **Single-process unified exe (v0.3)** — Combined engine + UI into one `.exe` to avoid cross-process issues. Still failed. WinRT callbacks never fired.

4. **Two-thread architecture (v0.5)** — WinRT on dedicated STA thread, WinForms on main thread, communicating via `ConcurrentQueue`. Still failed. The problem is process-wide, not thread-specific.

5. **Removed overlay during recording (v0.4)** — Didn't show the overlay while listening. Still failed in the single-exe because the `Form` objects existed in the process (even invisible/minimized).

### The diagnostic breakthrough

Created `test-diag.ps1` with incremental test levels (0–10), each adding one WinForms feature while running the engine as a child process:

| Test | Feature Added | Result |
|------|--------------|--------|
| 0 | Baseline (engine only) | PASS |
| 1 | WinForms assembly loaded | PASS |
| 2 | Hidden form created | PASS |
| 3 | DoEvents loop | PASS |
| 4 | Hotkey registered | PASS |
| 5 | Poll timer | PASS |
| 6 | NotifyIcon/tray icon | PASS |
| **7** | **Topmost overlay shown during recording** | **FAIL** |
| 8 | TopMost only (no Opacity) | FAIL |
| 9 | Opacity only (no TopMost) | FAIL |
| 10 | Plain visible form (no special styles) | FAIL |

**Finding:** Showing ANY visible WinForms `Form` during recording kills WinRT speech in the child engine process. This is a cross-process effect — the parent process showing a window somehow prevents the child's WinRT from accessing the microphone. The Windows microphone indicator in the taskbar doesn't even appear.

**But it was worse than that.** Even in a single process with Forms on a separate thread and WinRT on its own STA thread with its own message pump (v0.5), speech still failed. Creating `Form` objects anywhere in the process poisons WinRT's audio capture — even if the forms are invisible/minimized and on a different thread.

### What finally worked (v0.6–v0.8)

**Eliminate WinForms entirely.** Use pure Win32 API via P/Invoke for everything:

- **Message pump:** `PeekMessage`/`TranslateMessage`/`DispatchMessage` (no `Application.DoEvents()`)
- **Hotkey:** `GetAsyncKeyState` polling (no `Form` handle needed for `RegisterHotKey`)
- **Tray icon:** `Shell_NotifyIcon` with a message-only window (`CreateWindowEx` with `HWND_MESSAGE` parent)
- **Overlay:** `CreateWindowEx` with `WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE`, custom `WM_PAINT` handler with GDI drawing
- **Icons:** `CreateBitmap` + `CreateIconIndirect` for colored circle tray icons

The pure Win32 message-only window and overlay window do NOT interfere with WinRT speech. Only WinForms `Form` objects cause the issue. This confirms the problem is in the WinForms framework's process-wide initialization, not in Win32 windows themselves.

## Architecture (v0.8.0 — working)

Single compiled `.exe`, single thread, no WinForms:

```
winwhisper.exe
├── WinRT SpeechRecognizer (via reflection)
│   ├── ContinuousRecognitionSession
│   ├── HypothesisGenerated → console log
│   ├── ResultGenerated → accumulate text
│   └── Completed → session done
├── Win32 Tray Icon (Shell_NotifyIcon)
│   ├── Gray circle = idle
│   ├── Red circle = recording
│   ├── Right-click → Exit menu
│   └── Balloon notifications
├── Win32 Overlay Window (CreateWindowEx)
│   ├── Shown AFTER recording stops
│   ├── Dark background + colored dot + text
│   ├── Auto-hides after 2 seconds
│   └── Click-through, non-activating
├── GetAsyncKeyState hotkey polling (+ key)
├── SendInput for text output
└── PeekMessage/DispatchMessage loop
```

## Compilation

```
csc.exe /target:exe /out:winwhisper.exe ^
  /reference:System.Runtime.WindowsRuntime.dll ^
  /reference:Microsoft.CSharp.dll ^
  /reference:System.Core.dll ^
  winwhisper.cs
```

Note: NO `/reference:System.Windows.Forms.dll` or `System.Drawing.dll` — these are intentionally excluded.

## Key Technical Notes

- WinRT types loaded via `Type.GetType("..., ContentType=WindowsRuntime")` reflection
- WinRT events subscribed via `Expression.Lambda` typed handler delegates
- `WindowsRuntimeSystemExtensions.AsTask` for async operation awaiting
- `compileTask.Wait()` works on MTA thread (console app default, no `[STAThread]`)
- WinRT callbacks fire on thread pool threads, write to shared state (safe for single-consumer pattern)
- `StopAsync()` completes BEFORE `ResultGenerated` fires — must drain messages after stop
- `Shell_NotifyIcon` requires a window handle for callbacks — use message-only window (`HWND_MESSAGE`)
- `CreateBitmap` with 32bpp BGRA for custom colored icons (bottom-up row order)
- `PAINTSTRUCT.fErase`/`fRestore` are `bool` but marshal as 4-byte `BOOL` — struct layout must match
- `WndProcDelegate` must be stored in a static field to prevent GC collection

## Files

| File | Purpose |
|------|---------|
| `winwhisper.cs` | Main app source (pure Win32 + WinRT) |
| `winwhisper.exe` | Compiled binary |
| `winwhisper-engine.cs` | Standalone engine (stdin/stdout IPC, used by PS version) |
| `winwhisper-engine.exe` | Compiled standalone engine |
| `winwhisper.ps1` | PowerShell UI wrapper (uses engine.exe, has overlay bug) |
| `test-engine.ps1` | Engine integration test (works) |
| `test-diag.ps1` | Diagnostic: incremental WinForms feature testing |
| `test-winforms.ps1` | Diagnostic: Application.Run() vs WinRT |
| `AGENTS.md` | This file |
| `PD.md` | Original architecture plan |
| `README.md` | User documentation |
