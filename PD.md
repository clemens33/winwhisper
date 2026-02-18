# PD.md — WinWhisper: Push-to-Talk Voice Dictation for Windows 11

## Project Summary

A single-file PowerShell tool that provides push-to-talk voice dictation for developers using AI coding agents (Claude Code, OpenCode, Codex CLI) in Windows Terminal / WSL2. Uses Windows 11's built-in cloud speech recognition engine — same quality as Win+H Voice Typing — but with full programmatic control: hotkey start, hotkey stop, no silence timeout, direct text capture.

**One-line install. One file. Zero dependencies beyond stock Windows 11.**

---

## Problem

Windows 11 Voice Typing (Win+H) uses Microsoft's cloud STT — good accuracy, multilingual, free, no API key. But it's unsuitable for developer workflows:

- Click-based UI, no real push-to-talk hotkey
- Auto-stops after ~5 seconds of silence (thinking pauses kill it)
- No auto-Enter after dictation (needed for terminal agents)
- No programmatic text capture (types directly into focused field)
- No history / copy-last-message
- Toolbar sometimes covers content

This tool provides the same cloud STT quality with a proper developer UX.

---

## Core Concept

```
User presses configurable hotkey (e.g. Numpad+)
    → UWP SpeechRecognizer starts ContinuousRecognitionSession
    → Overlay shows "🔴 Listening..." indicator
    → User speaks, partial results stream via HypothesisGenerated events
    → User pauses to think — no timeout, session stays open
    → User presses hotkey again
    → ContinuousRecognitionSession.StopAsync() fires final ResultGenerated
    → Accumulated text typed into focused field via SendInput
    → Optionally sends Enter after configurable delay
    → Text stored in history for copy-to-clipboard
```

The tool does NOT use Win+H. It uses the same cloud engine directly via the `Windows.Media.SpeechRecognition` UWP API, which gives full start/stop control and direct text capture.

---

## Architecture: Two Speech Engines

### Primary: UWP `Windows.Media.SpeechRecognition.SpeechRecognizer`

Same Azure cloud STT that powers Win+H, but accessed programmatically:

```
SpeechRecognizer
├── ContinuousRecognitionSession
│   ├── StartAsync()           → starts listening
│   ├── StopAsync()            → stops listening
│   ├── ResultGenerated event  → final text chunks
│   └── Completed event        → session ended
├── HypothesisGenerated event  → real-time partial text
├── CompileConstraintsAsync()  → one-time init
└── Constructor(Language)      → language selection
```

**Why this is better than Win+H:**

- Full start/stop control via hotkey — no silence timeout
- Direct text capture via events — no keyboard hook needed
- Partial results streaming — show what user is saying in real-time
- No Voice Typing toolbar UI cluttering the screen
- Configurable `AutoStopSilenceTimeout` (up to minutes, or effectively disabled)

**Prerequisite:** "Online speech recognition" must be enabled:
`Settings → Privacy & security → Speech → Online speech recognition`

If not enabled, the API throws a specific privacy error. The tool should detect this and open `ms-settings:privacy-speech` automatically.

### Fallback: Win+H Re-trigger Wrapper

If the UWP API doesn't work (e.g., missing permissions, language not supported), fall back to wrapping Win+H with an auto-re-trigger mechanism:

```
Hotkey pressed → Send Win+H → Start polling timer
    ↓
Every 3s: Is Voice Typing window still alive? (FindWindow)
    YES → do nothing
    NO  → re-send Win+H (re-activate)
    ↓
Hotkey pressed → stop timer → Send Win+H to close
```

This has a brief ~200ms gap during re-trigger but is guaranteed to work.

### ⚠️ Language Risk

The UWP continuous dictation docs state: **"For PCs and laptops, only en-US is recognized."** This appears to be outdated (the docs are UWP-era, pre-Windows 11). Rick Strahl's March 2025 article shows language configuration working in a WPF desktop app. Win+H itself supports 50+ languages including German.

**Must test early:** Create recognizer with `new SpeechRecognizer(new Language("de-DE"))` and verify cloud dictation works on desktop Windows 11. If it doesn't, German users must use the Win+H fallback.

---

## Technical Stack

| Component | Technology | Why |
|---|---|---|
| Language | PowerShell 5.1 (Windows PowerShell) | Ships with every Windows 11. NOT PowerShell 7 (Core). |
| Speech Engine | `Windows.Media.SpeechRecognition` (WinRT/UWP) | Cloud STT, full control, ships with Windows 11. |
| WinRT Interop | `[Type, Namespace, ContentType=WindowsRuntime]` syntax | PS 5.1 on .NET Framework can load WinRT types natively. |
| C# Bridge | `Add-Type -TypeDefinition` (embedded C#) | Handles WinRT async + events (PS can't do this directly). |
| UI Framework | `System.Windows.Forms` (.NET Framework 4.8) | Tray icon, overlay, settings dialog. Ships with Windows. |
| Win32 APIs | P/Invoke via `Add-Type -MemberDefinition` | `RegisterHotKey`, `SendInput` from `user32.dll`. |
| Settings | JSON file | `ConvertTo-Json` / `ConvertFrom-Json` built into PS. |
| Install | PowerShell script | Downloads to `%LOCALAPPDATA%`, creates startup shortcut. |

**No external dependencies. No .NET 8. No NuGet packages. No admin rights.**

**Critical: Must use Windows PowerShell 5.1** (not PowerShell 7/Core). The `ContentType=WindowsRuntime` type loading only works in PS 5.1 which runs on .NET Framework. PowerShell 7 on .NET Core cannot load WinRT types this way.

---

## Development Environment

This project is developed on WSL/Linux. Output is a `.ps1` file that runs on Windows.

### Dev workflow from WSL

```bash
# Edit the script
vim winwhisper.ps1

# Test from WSL — MUST use powershell.exe (5.1), not pwsh.exe (7)
powershell.exe -ExecutionPolicy Bypass -File "$(wslpath -w ./winwhisper.ps1)"

# Quick iteration: copy to Windows path
cp winwhisper.ps1 /mnt/c/Users/$USER/winwhisper.ps1
powershell.exe -ExecutionPolicy Bypass -File "C:\\Users\\$USER\\winwhisper.ps1"
```

### Important: PowerShell 5.1 vs 7

```bash
# Windows PowerShell 5.1 — what we need
powershell.exe    # Located at C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe

# PowerShell 7+ (Core) — DO NOT USE for this project
pwsh.exe          # Cannot load WinRT types
```

### Testing

All testing happens on the Windows side (speech, hotkeys, tray icon require Windows GUI). Use `-Debug` flag for console logging.

**First test milestone:** Get speech recognition working standalone before building any UI. A minimal test script:

```powershell
# test-speech.ps1 — validate UWP speech recognition works
# Run with: powershell.exe -ExecutionPolicy Bypass -File test-speech.ps1

$null = [Windows.Media.SpeechRecognition.SpeechRecognizer, Windows.Media.SpeechRecognition, ContentType=WindowsRuntime]
$null = [Windows.Media.SpeechRecognition.SpeechRecognitionTopicConstraint, Windows.Media.SpeechRecognition, ContentType=WindowsRuntime]

Write-Host "SpeechRecognizer type loaded successfully"
# If this works, WinRT interop is confirmed
```

---

## File Structure

```
repo/
├── PD.md                          # This document
├── README.md                      # User-facing docs + install instructions
├── winwhisper.ps1              # THE TOOL — single file, complete application
├── install.ps1                    # Remote installer script
├── test-speech.ps1                # Minimal speech test (dev only)
└── .github/
    └── workflows/
        └── release.yml            # Optional: tag-based release
```

### Installed on user's machine

```
%LOCALAPPDATA%\WinWhisper\
├── winwhisper.ps1              # The tool
└── settings.json                  # User config (created on first run)

%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\
└── WinWhisper.lnk              # Autostart shortcut (optional)
```

---

## Script Architecture

### Main Script Structure (`winwhisper.ps1`)

The script is organized into these sections, in order:

```
 1. PARAM BLOCK           — CLI flags: -Debug, -Settings, -Uninstall, -Fallback
 2. CONSTANTS             — version, paths, defaults, VK codes
 3. C# BRIDGE (Add-Type)  — WinRT speech wrapper + async helpers + event bridge
 4. NATIVE METHODS        — P/Invoke for RegisterHotKey, SendInput, FindWindow
 5. WINFORMS TYPES        — HotkeyForm (WndProc), OverlayForm (click-through)
 6. SETTINGS SERVICE      — load/save JSON config
 7. SPEECH SERVICE         — init/start/stop speech, text accumulation
 8. TEXT OUTPUT SERVICE    — SendInput to type captured text into focused field
 9. OVERLAY CONTROLLER    — show/hide/update overlay
10. TRAY APPLICATION      — NotifyIcon + context menu + main message loop
11. ENTRY POINT           — single-instance check, arg parsing, launch
```

### Application Flow

```
┌─────────────────────────────────────────────────┐
│                  ENTRY POINT                     │
│                                                  │
│  1. Parse CLI args                               │
│  2. Single-instance check (Mutex)                │
│  3. Load settings from JSON                      │
│  4. Compile C# bridge via Add-Type               │
│  5. Initialize SpeechService                     │
│     → Load WinRT types                           │
│     → Create SpeechRecognizer                    │
│     → Add DictationGrammar                       │
│     → CompileConstraintsAsync()                  │
│     → Wire up ResultGenerated + Hypothesis       │
│  6. Create hidden HotkeyForm (message pump)      │
│  7. Register global hotkey                       │
│  8. Create NotifyIcon (tray)                     │
│  9. Create OverlayForm (hidden initially)        │
│ 10. [Application]::Run($hotkeyForm)              │
│                                                  │
│  On WM_HOTKEY:                                   │
│    IF not listening:                             │
│      → ContinuousRecognitionSession.StartAsync() │
│      → Show overlay "Listening..."               │
│      → Update tray icon to red                   │
│    IF listening:                                 │
│      → ContinuousRecognitionSession.StopAsync()  │
│      → Wait for final ResultGenerated            │
│      → Type accumulated text via SendInput       │
│      → Optionally send Enter                     │
│      → Store in history                          │
│      → Hide overlay                              │
│      → Update tray icon to idle                  │
│                                                  │
│  On ResultGenerated (background thread):         │
│    → Append result text to accumulator           │
│    → Update overlay with partial text            │
│                                                  │
│  On HypothesisGenerated (background thread):     │
│    → Update overlay with hypothesis text         │
│                                                  │
│  On Exit:                                        │
│    → Unregister hotkey                           │
│    → Dispose SpeechRecognizer                    │
│    → Dispose NotifyIcon                          │
│    → Application.Exit()                          │
└─────────────────────────────────────────────────┘
```

---

## Implementation Details

### 1. The C# Bridge Class (Critical Component)

PowerShell 5.1 can LOAD WinRT types but cannot:

- Await WinRT `IAsyncAction` / `IAsyncOperation` (they're not `Task`)
- Subscribe to WinRT events with `Register-ObjectEvent`

Solution: an embedded C# class compiled via `Add-Type` that wraps all WinRT interactions and exposes standard .NET events.

```csharp
// This entire block goes into Add-Type -TypeDefinition
using System;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Windows.Media.SpeechRecognition;
using Windows.Globalization;

public class SpeechBridge : IDisposable
{
    private SpeechRecognizer _recognizer;
    private StringBuilder _accumulated = new StringBuilder();
    private bool _isListening;
    
    // .NET events that PowerShell CAN subscribe to
    public event EventHandler<string> ResultGenerated;    // final text chunk
    public event EventHandler<string> HypothesisGenerated; // partial/live text
    public event EventHandler<string> SessionCompleted;    // session ended
    public event EventHandler<string> ErrorOccurred;       // error with message
    
    public bool IsListening => _isListening;
    public string AccumulatedText => _accumulated.ToString();

    public void Initialize(string language = null)
    {
        try
        {
            if (string.IsNullOrEmpty(language))
                _recognizer = new SpeechRecognizer();
            else
                _recognizer = new SpeechRecognizer(new Language(language));
            
            // Add dictation grammar (uses cloud web service)
            var dictation = new SpeechRecognitionTopicConstraint(
                SpeechRecognitionScenario.Dictation, "dictation");
            _recognizer.Constraints.Add(dictation);
            
            // Set long silence timeout
            _recognizer.ContinuousRecognitionSession.AutoStopSilenceTimeout =
                TimeSpan.FromMinutes(5);
            
            // Wire WinRT events to .NET events
            _recognizer.ContinuousRecognitionSession.ResultGenerated += (s, e) =>
            {
                var text = e.Result.Text;
                if (!string.IsNullOrWhiteSpace(text))
                {
                    if (_accumulated.Length > 0) _accumulated.Append(" ");
                    _accumulated.Append(text);
                    ResultGenerated?.Invoke(this, text);
                }
            };
            
            _recognizer.HypothesisGenerated += (s, e) =>
            {
                HypothesisGenerated?.Invoke(this, e.Hypothesis.Text);
            };
            
            _recognizer.ContinuousRecognitionSession.Completed += (s, e) =>
            {
                _isListening = false;
                SessionCompleted?.Invoke(this, e.Status.ToString());
            };
            
            // Compile constraints — MUST complete before StartAsync
            // .AsTask() converts WinRT IAsyncOperation to Task
            _recognizer.CompileConstraintsAsync().AsTask().Wait();
        }
        catch (Exception ex)
        {
            ErrorOccurred?.Invoke(this, ex.Message);
            throw;
        }
    }
    
    public void Start()
    {
        if (_isListening) return;
        _accumulated.Clear();
        _recognizer.ContinuousRecognitionSession.StartAsync().AsTask().Wait();
        _isListening = true;
    }
    
    public string Stop()
    {
        if (!_isListening) return _accumulated.ToString();
        try
        {
            // Small delay to capture final words being processed
            Thread.Sleep(200);
            _recognizer.ContinuousRecognitionSession.StopAsync().AsTask().Wait();
        }
        catch { }
        _isListening = false;
        return _accumulated.ToString();
    }
    
    public void Dispose()
    {
        if (_isListening)
        {
            try { _recognizer.ContinuousRecognitionSession.CancelAsync().AsTask().Wait(); }
            catch { }
        }
        _recognizer?.Dispose();
    }
}
```

**Assembly references needed for Add-Type:**

```powershell
$winmdPath = "$env:SystemRoot\System32\WinMetadata"
$refs = @(
    "$winmdPath\Windows.Media.winmd",
    "$winmdPath\Windows.Foundation.winmd",
    "$winmdPath\Windows.Globalization.winmd"
)

Add-Type -TypeDefinition $csharpCode -ReferencedAssemblies $refs
```

**⚠️ This is the highest-risk part of the project.** The WinRT ↔ .NET Framework ↔ PowerShell interop chain is fragile. Rick Strahl's article documents painful issues with `IAsyncAction.AsTask()` requiring reflection workarounds in some configurations.

**If `.AsTask()` doesn't resolve at compile time**, use a reflection-based fallback:

```csharp
public static class AsyncHelper
{
    public static void Await(object asyncAction)
    {
        // Use reflection to find AsTask extension method
        var extensionType = typeof(System.WindowsRuntimeSystemExtensions);
        var methods = extensionType.GetMethods();
        foreach (var method in methods)
        {
            if (method.Name == "AsTask" && method.GetParameters().Length == 1)
            {
                var paramType = method.GetParameters()[0].ParameterType;
                if (paramType.IsAssignableFrom(asyncAction.GetType()))
                {
                    var task = (Task)method.Invoke(null, new[] { asyncAction });
                    task.Wait();
                    return;
                }
            }
        }
        // Fallback: poll IAsyncInfo.Status
        dynamic action = asyncAction;
        while ((int)action.Status == 0) // Started
            Thread.Sleep(50);
    }
}
```

**Development strategy:** Build and test the C# bridge FIRST in isolation before integrating with the rest of the script. Create a `test-speech.ps1` that only tests speech recognition.

### 2. P/Invoke Definitions

```powershell
$NativeMethods = @"
    [DllImport("user32.dll")]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll")]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll")]
    public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    // INPUT struct for SendInput (Unicode text typing)
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT {
        public uint type;
        public INPUTUNION union;
    }
    
    [StructLayout(LayoutKind.Explicit)]
    public struct INPUTUNION {
        [FieldOffset(0)] public KEYBDINPUT ki;
    }
    
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }
"@
Add-Type -MemberDefinition $NativeMethods -Name "WinAPI" -Namespace "WinWhisper"
```

Key constants:

```
VK_RETURN = 0x0D
VK_ADD    = 0x6B   (Numpad+)
WM_HOTKEY = 0x0312
INPUT_KEYBOARD = 1
KEYEVENTF_UNICODE = 0x0004
KEYEVENTF_KEYUP = 0x0002
```

### 3. Text Output via SendInput

Instead of letting Voice Typing type into the field (Win+H approach), we now have the text as a string and need to inject it. Use `SendInput` with `KEYEVENTF_UNICODE` to type each character:

```powershell
function Send-Text([string]$text) {
    # Build INPUT array — two entries per char (keydown + keyup)
    foreach ($char in $text.ToCharArray()) {
        # Create KEYBDINPUT with wScan = char code, KEYEVENTF_UNICODE flag
        # Send via SendInput
    }
}

function Send-Enter {
    # Send VK_RETURN keydown + keyup via SendInput
}
```

**Why SendInput over clipboard paste:** Clipboard paste (Ctrl+V) would clobber the user's clipboard. SendInput simulates real typing, works in all terminals, and doesn't touch the clipboard.

**Caveat:** For very long text, SendInput character-by-character is slow. For text > 200 chars, consider clipboard paste with clipboard save/restore:

```powershell
$saved = Get-Clipboard
Set-Clipboard -Value $text
# Send Ctrl+V
Set-Clipboard -Value $saved
```

### 4. WinForms: Hidden HotkeyForm + OverlayForm

Both defined via embedded C# for proper `WndProc` / `CreateParams` override:

```csharp
using System;
using System.Windows.Forms;
using System.Drawing;

// Receives WM_HOTKEY messages
public class HotkeyForm : Form
{
    public event EventHandler HotkeyPressed;
    
    public HotkeyForm()
    {
        this.Visible = false;
        this.ShowInTaskbar = false;
        this.FormBorderStyle = FormBorderStyle.None;
        this.WindowState = FormWindowState.Minimized;
    }
    
    protected override void WndProc(ref Message m)
    {
        if (m.Msg == 0x0312) // WM_HOTKEY
            HotkeyPressed?.Invoke(this, EventArgs.Empty);
        base.WndProc(ref m);
    }
}

// Click-through, always-on-top overlay
public class OverlayForm : Form
{
    private Label _label;
    
    public OverlayForm()
    {
        this.FormBorderStyle = FormBorderStyle.None;
        this.TopMost = true;
        this.ShowInTaskbar = false;
        this.StartPosition = FormStartPosition.Manual;
        this.BackColor = Color.FromArgb(30, 30, 30);
        this.Opacity = 0.9;
        this.Size = new Size(300, 40);
        
        _label = new Label();
        _label.ForeColor = Color.FromArgb(239, 68, 68);
        _label.Font = new Font("Segoe UI", 10, FontStyle.Bold);
        _label.AutoSize = true;
        _label.Location = new Point(12, 10);
        this.Controls.Add(_label);
    }
    
    public void SetText(string text)
    {
        if (this.InvokeRequired)
            this.Invoke(new Action(() => _label.Text = text));
        else
            _label.Text = text;
    }
    
    // Click-through window styles
    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x80000;     // WS_EX_LAYERED
            cp.ExStyle |= 0x20;        // WS_EX_TRANSPARENT (click-through)
            cp.ExStyle |= 0x08000000;  // WS_EX_NOACTIVATE
            cp.ExStyle |= 0x80;        // WS_EX_TOOLWINDOW (hide from Alt+Tab)
            return cp;
        }
    }
    
    public void PositionNearTray()
    {
        var screen = Screen.PrimaryScreen.WorkingArea;
        this.Location = new Point(screen.Right - 315, screen.Bottom - 55);
    }
}
```

### 5. Toggle Logic

```powershell
$script:isListening = $false
$script:speechBridge = $null  # initialized in startup
$script:lastHotkeyTime = [DateTime]::MinValue

function Toggle-VoiceRecognition {
    $now = [DateTime]::Now
    $timeSinceLast = ($now - $script:lastHotkeyTime).TotalMilliseconds
    $isDoublePress = $settings.doublePress.enabled -and ($timeSinceLast -lt $settings.doublePress.interval)
    $script:lastHotkeyTime = $now

    if ($script:isListening) {
        # STOP
        $text = $script:speechBridge.Stop()
        $script:isListening = $false
        
        Update-Overlay -Text "Done" -State "done"
        Update-TrayIcon -State "idle"
        
        if ($text.Length -gt 0) {
            Send-Text $text
            Add-History $text
            
            # Auto-Enter logic
            $shouldEnter = $settings.autoEnter -or $isDoublePress
            if ($shouldEnter) {
                $timer = New-Object System.Windows.Forms.Timer
                $timer.Interval = $settings.autoEnterDelay
                $timer.Add_Tick({
                    $this.Stop(); $this.Dispose()
                    Send-Enter
                })
                $timer.Start()
            }
        }
        
        # Hide overlay after brief display
        $hideTimer = New-Object System.Windows.Forms.Timer
        $hideTimer.Interval = 1200
        $hideTimer.Add_Tick({
            $this.Stop(); $this.Dispose()
            $script:overlay.Hide()
        })
        $hideTimer.Start()
        
    } else {
        # START
        $script:speechBridge.Start()
        $script:isListening = $true
        
        Update-Overlay -Text "Listening..." -State "recording"
        Update-TrayIcon -State "recording"
    }
}
```

### 6. Hypothesis Event Handling (Real-time Overlay)

Wire up the hypothesis event to show partial transcription in the overlay:

```powershell
Register-ObjectEvent -InputObject $script:speechBridge -EventName HypothesisGenerated -Action {
    $text = $Event.SourceEventArgs  # string
    $display = if ($text.Length -gt 40) { "..." + $text.Substring($text.Length - 40) } else { $text }
    $script:overlay.SetText("$display")
}

Register-ObjectEvent -InputObject $script:speechBridge -EventName ResultGenerated -Action {
    $text = $Event.SourceEventArgs
    if ($script:debugMode) { Write-Host "[Result] $text" }
}
```

### 7. Settings Schema

File: `%APPDATA%\WinWhisper\settings.json`

```json
{
    "version": 1,
    "hotkey": {
        "key": "Add",
        "modifiers": []
    },
    "language": null,
    "mode": "toggle",
    "autoEnter": false,
    "autoEnterDelay": 800,
    "doublePress": {
        "enabled": true,
        "interval": 400
    },
    "overlay": {
        "enabled": true,
        "showHypothesis": true,
        "position": "tray"
    },
    "history": {
        "maxEntries": 20
    },
    "textOutput": {
        "method": "sendInput",
        "clipboardFallbackLength": 200
    },
    "autoStart": false,
    "engine": "uwp"
}
```

**`engine` field:** `"uwp"` (primary, UWP SpeechRecognizer API) or `"winh"` (fallback, Win+H with re-trigger)

**`language` field:** `null` (system default) or IETF tag like `"en-US"`, `"de-DE"`

### 8. Settings Form

WinForms dialog (~400x500px) with:

- **Hotkey section:** TextBox capturing next keypress (read-only, captures modifiers)
- **Language:** Dropdown populated from `SpeechRecognizer.SupportedTopicLanguages`
- **Mode:** Radio buttons (Toggle / Hold-to-talk)
- **Auto-Enter:** Checkbox + NumericUpDown for delay (ms)
- **Double-press:** Checkbox + interval
- **Overlay:** Checkbox enable + show hypothesis toggle
- **Text output:** Radio (SendInput / Clipboard paste)
- **Engine:** Radio (UWP API / Win+H fallback)
- **Auto-start:** Checkbox
- **Save / Cancel** buttons

Build via `Add-Type` as C# WinForms class or assemble in PowerShell with manual positioning.

### 9. Tray Icon

```powershell
$trayIcon = New-Object System.Windows.Forms.NotifyIcon
$trayIcon.Text = "WinWhisper"
$trayIcon.Visible = $true
$trayIcon.Icon = New-TrayIcon "idle"

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menuStatus = $menu.Items.Add("Ready"); $menuStatus.Enabled = $false
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$menuCopyLast = $menu.Items.Add("Copy last transcription")
$menuCopyLast.Add_Click({ Copy-LastTranscription })
$menuSettings = $menu.Items.Add("Settings...")
$menuSettings.Add_Click({ Show-SettingsDialog })
$menuAutoStart = $menu.Items.Add("Start with Windows")
$menuAutoStart.CheckOnClick = $true; $menuAutoStart.Checked = $settings.autoStart
$menuAutoStart.Add_Click({ Toggle-AutoStart })
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$menuExit = $menu.Items.Add("Exit")
$menuExit.Add_Click({ Exit-App })
$trayIcon.ContextMenuStrip = $menu
```

Tray icon generation (simple colored circles):

```powershell
function New-TrayIcon([string]$state) {
    $bmp = New-Object System.Drawing.Bitmap(16, 16)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    switch ($state) {
        "idle"      { $g.FillEllipse([System.Drawing.Brushes]::Gray, 3, 3, 10, 10) }
        "recording" { $g.FillEllipse([System.Drawing.Brushes]::Red, 2, 2, 12, 12) }
    }
    $g.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}
```

### 10. Auto-Start + Single-Instance

```powershell
# Auto-start
$startupDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"
$shortcutPath = Join-Path $startupDir "WinWhisper.lnk"

function Set-AutoStart([bool]$enabled) {
    if ($enabled) {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = "powershell.exe"
        $shortcut.Arguments = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
        $shortcut.WorkingDirectory = (Split-Path $scriptPath)
        $shortcut.Save()
    } else {
        if (Test-Path $shortcutPath) { Remove-Item $shortcutPath }
    }
}

# Single-instance
$mutex = New-Object System.Threading.Mutex($false, "WinWhisper_SingleInstance")
if (-not $mutex.WaitOne(0, $false)) {
    [System.Windows.Forms.MessageBox]::Show(
        "WinWhisper is already running. Check the system tray.",
        "WinWhisper", 'OK', 'Information')
    exit
}
```

---

## Win+H Fallback Engine

Activated via `-Fallback` flag or `engine: "winh"` setting.

### Win+H Activation

```powershell
function Send-WinH {
    [WinWhisper.WinAPI]::keybd_event(0x5B, 0, 0, [UIntPtr]::Zero)     # Win down
    Start-Sleep -Milliseconds 30
    [WinWhisper.WinAPI]::keybd_event(0x48, 0, 0, [UIntPtr]::Zero)     # H down
    Start-Sleep -Milliseconds 30
    [WinWhisper.WinAPI]::keybd_event(0x48, 0, 2, [UIntPtr]::Zero)     # H up
    Start-Sleep -Milliseconds 30
    [WinWhisper.WinAPI]::keybd_event(0x5B, 0, 2, [UIntPtr]::Zero)     # Win up
}
```

### Re-trigger Timer

```powershell
$retriggerTimer = New-Object System.Windows.Forms.Timer
$retriggerTimer.Interval = 3000
$retriggerTimer.Add_Tick({
    # Check if Voice Typing window is still alive
    $hwnd = [WinWhisper.WinAPI]::FindWindow("VoiceTypingFlyout", $null)
    if ($hwnd -eq [IntPtr]::Zero -and $script:isListening) {
        if ($script:debugMode) { Write-Host "[Re-trigger] Win+H" }
        Send-WinH
    }
})
```

**Note:** The exact window class name for Voice Typing needs discovery via Spy++ or `EnumWindows`.

In fallback mode, text goes directly into the focused field (no capture). "Copy last" is disabled. Acceptable since UWP is primary.

---

## Install Script (`install.ps1`)

```powershell
# Usage: irm https://raw.githubusercontent.com/<user>/winwhisper/main/install.ps1 | iex
param([switch]$Uninstall)

$installDir = Join-Path $env:LOCALAPPDATA "WinWhisper"
$scriptUrl = "https://raw.githubusercontent.com/<user>/winwhisper/main/winwhisper.ps1"
$scriptPath = Join-Path $installDir "winwhisper.ps1"
$startupDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"
$shortcutPath = Join-Path $startupDir "WinWhisper.lnk"

if ($Uninstall) {
    Write-Host "Uninstalling WinWhisper..." -ForegroundColor Yellow
    Get-Process powershell | Where-Object { $_.CommandLine -like "*winwhisper*" } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    if (Test-Path $installDir) { Remove-Item $installDir -Recurse -Force }
    if (Test-Path $shortcutPath) { Remove-Item $shortcutPath -Force }
    $settingsDir = Join-Path $env:APPDATA "WinWhisper"
    if (Test-Path $settingsDir) { Remove-Item $settingsDir -Recurse -Force }
    Write-Host "Uninstalled." -ForegroundColor Green
    return
}

Write-Host "Installing WinWhisper..." -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $installDir | Out-Null
Invoke-WebRequest -Uri $scriptUrl -OutFile $scriptPath

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = "powershell.exe"
$shortcut.Arguments = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
$shortcut.WorkingDirectory = $installDir
$shortcut.Save()

Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`"" -WindowStyle Hidden

Write-Host ""
Write-Host "Installed!" -ForegroundColor Green
Write-Host "  Location: $scriptPath"
Write-Host "  Hotkey:   Numpad+ (configurable via tray icon)"
```

---

## CLI Flags

```
winwhisper.ps1                    # Normal launch (tray mode, UWP engine)
winwhisper.ps1 -Debug             # Console window + verbose logging
winwhisper.ps1 -Fallback          # Force Win+H fallback engine
winwhisper.ps1 -Settings          # Open settings dialog immediately
winwhisper.ps1 -Uninstall         # Remove autostart + settings
winwhisper.ps1 -TestSpeech        # Run speech recognition test and exit
```

---

## Development Plan — Build Order

### Phase 0: Validate WinRT Speech Interop (CRITICAL — DO THIS FIRST)

Before building anything else, confirm the core tech works:

1. Create `test-speech.ps1` that loads WinRT types in PowerShell 5.1
2. Create minimal C# bridge via Add-Type that initializes SpeechRecognizer
3. Test `CompileConstraintsAsync()` completes successfully
4. Test `ContinuousRecognitionSession.StartAsync()` / `StopAsync()`
5. Test `ResultGenerated` event fires and delivers text
6. **Test German: `new SpeechRecognizer(new Language("de-DE"))`** — does cloud dictation work?
7. Test `AutoStopSilenceTimeout` — can we pause >5s without session dying?

If any step fails, debug that specific interop issue before proceeding.

If German fails on UWP: make Win+H fallback the primary path for non-English.

### Phase 1: Core Loop (v0.1 — ship target)

- [ ] C# SpeechBridge class (init, start, stop, events)
- [ ] P/Invoke for RegisterHotKey, SendInput
- [ ] HotkeyForm (WndProc for WM_HOTKEY)
- [ ] Toggle logic: hotkey → start/stop speech
- [ ] Text output: accumulated text → SendInput into focused field
- [ ] System tray icon (idle / recording states)
- [ ] Tray context menu (Copy last, Settings, Exit)
- [ ] Overlay indicator (Listening / Done)
- [ ] Click-through overlay (WS_EX_TRANSPARENT)
- [ ] Settings JSON (load/save/defaults)
- [ ] Auto-Enter with configurable delay
- [ ] Single-instance Mutex
- [ ] `-Debug` flag with console logging
- [ ] Clean exit with resource disposal

### Phase 2: Polish (v0.2)

- [ ] Settings dialog (WinForms)
- [ ] Hotkey picker (capture key + modifiers)
- [ ] Language selector (from SupportedTopicLanguages)
- [ ] Double-press detection (double-tap = transcribe + Enter)
- [ ] Transcription history ring buffer
- [ ] History submenu in tray (last 5)
- [ ] Real-time hypothesis display in overlay
- [ ] Auto-start management (startup shortcut)
- [ ] Win+H fallback engine
- [ ] Install script

### Phase 3: Refinement (v1.0)

- [ ] Hold-to-talk mode (hold hotkey = record, release = stop)
- [ ] Per-app profiles (auto-enter only in Windows Terminal)
- [ ] Text spacing cleanup (handle sentence boundaries)
- [ ] Clipboard paste fallback for long text
- [ ] Error recovery (restart recognition on failure)
- [ ] Update checker

---

## Edge Cases & Known Issues

1. **WinRT Async Interop:** The `.AsTask()` extension method may not resolve cleanly when compiled via Add-Type against .NET Framework. May need reflection-based workaround (see Rick Strahl's article and AsyncHelper fallback above). Test in Phase 0.

2. **PowerShell 5.1 ONLY:** `ContentType=WindowsRuntime` type loading does NOT work in PowerShell 7 (Core). Script must run via `powershell.exe`, not `pwsh.exe`.

3. **Speech Privacy Settings:** Users must enable "Online speech recognition" in Windows Settings. If disabled, API throws privacy error. Detect and auto-open `ms-settings:privacy-speech`.

4. **Focus and SendInput:** Target window must have focus when text is typed. If user switched windows during recording, text goes to wrong window. Mitigation: save foreground window handle on start, restore before typing.

5. **AutoStopSilenceTimeout:** May have a practical maximum. Rick Strahl sets 1 minute. Test with 5 minutes. If cloud disconnects anyway, detect `Completed` event with `TimeoutExceeded` and auto-restart session.

6. **Thread Safety:** WinRT speech events fire on background threads. All UI updates must be marshaled via `Control.Invoke()`.

7. **Microphone Access:** First run may trigger Windows microphone permission dialog.

8. **Terminal Compatibility:** SendInput works in Windows Terminal, cmd.exe, PowerShell. May have issues with some Electron-based terminals.

9. **Multiple Monitors:** Overlay uses `Screen.PrimaryScreen.WorkingArea`. Multi-monitor is v1.0.

10. **Antivirus:** `Add-Type` compiling C# at runtime may trigger AV flags. Document this.

---

## Testing Checklist

```
Phase 0 — WinRT Validation:
[ ] WinRT types load in PowerShell 5.1
[ ] C# bridge compiles via Add-Type with WinMetadata references
[ ] SpeechRecognizer initializes
[ ] CompileConstraintsAsync completes
[ ] StartAsync / StopAsync work
[ ] ResultGenerated fires with correct text
[ ] HypothesisGenerated fires with partial text
[ ] English dictation works (en-US)
[ ] German dictation works (de-DE) ← CRITICAL
[ ] AutoStopSilenceTimeout respected (>5s pause doesn't kill session)
[ ] Error handling for missing privacy settings

Phase 1 — Core:
[ ] Global hotkey registers and fires
[ ] Toggle: press to start, press to stop
[ ] Text appears in focused field after stop
[ ] Tray icon appears and changes states
[ ] Context menu works
[ ] Copy last transcription
[ ] Overlay shows during recording, is click-through
[ ] Auto-Enter sends Enter after delay
[ ] Settings load/save
[ ] Single instance enforced
[ ] -Debug shows console with logging
[ ] Clean exit disposes everything
[ ] Works in Windows Terminal with Claude Code
[ ] Works in Notepad (sanity check)
```

---

## References

- [UWP SpeechRecognizer API](https://learn.microsoft.com/en-us/uwp/api/windows.media.speechrecognition.speechrecognizer)
- [Enable Continuous Dictation (Microsoft)](https://learn.microsoft.com/en-us/windows/apps/develop/input/enable-continuous-dictation)
- [Rick Strahl: Using Windows.Media SpeechRecognition in WPF (March 2025)](https://weblog.west-wind.com/posts/2025/Mar/24/Using-WindowsMedia-SpeechRecognition-in-WPF)
- [Rick Strahl: VoiceDictation Class (gist)](https://gist.github.com/RickStrahl/9b250c8bff67edd26b79e614b16955eb)
- [Keith Hill: Calling WinRT Async from PowerShell](https://rkeithhill.wordpress.com/2013/09/30/calling-winrt-async-methods-from-windows-powershell/)
- [Raymond Chen: WinRT from PowerShell](https://devblogs.microsoft.com/oldnewthing/20230303-00/?p=107894)
- [WinRT Toast from PowerShell (event wrapping)](https://deletethis.net/dave/2016-06/WinRT+Toast+from+PowerShell/)
- [RegisterHotKey](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerhotkey)
- [SendInput](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput)
