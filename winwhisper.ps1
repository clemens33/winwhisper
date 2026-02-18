<#
.SYNOPSIS
    WinWhisper - Push-to-talk voice dictation for Windows 11

.DESCRIPTION
    System tray tool providing push-to-talk voice dictation using Windows 11's
    built-in cloud speech recognition (same engine as Win+H Voice Typing).
    Hotkey toggles listening on/off, text is typed into the focused field via SendInput.

    Must run on Windows PowerShell 5.1 (powershell.exe, NOT pwsh.exe).

.PARAMETER Debug
    Show console window with verbose logging.

.PARAMETER Fallback
    Force Win+H fallback engine instead of UWP API.

.PARAMETER ShowSettings
    Open settings dialog immediately on launch.

.PARAMETER Uninstall
    Remove autostart shortcut and settings, then exit.

.PARAMETER TestSpeech
    Run a quick speech recognition test and exit.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File winwhisper.ps1
    powershell.exe -ExecutionPolicy Bypass -File winwhisper.ps1 -Debug
#>
param(
    [switch]$Debug,
    [switch]$Fallback,
    [switch]$ShowSettings,
    [switch]$Uninstall,
    [switch]$TestSpeech
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# 1. CONSTANTS
# ============================================================================

$script:VERSION = "0.1.0"
$script:APP_NAME = "WinWhisper"
$script:MUTEX_NAME = "WinWhisper_SingleInstance"
$script:SETTINGS_DIR = Join-Path $env:APPDATA "WinWhisper"
$script:SETTINGS_FILE = Join-Path $script:SETTINGS_DIR "settings.json"
$script:STARTUP_DIR = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"
$script:SHORTCUT_PATH = Join-Path $script:STARTUP_DIR "WinWhisper.lnk"
$script:SCRIPT_PATH = $MyInvocation.MyCommand.Path

# Virtual key codes
$script:VK_ADD = 0x6B        # Numpad+
$script:VK_RETURN = 0x0D     # Enter
$script:WM_HOTKEY = 0x0312
$script:HOTKEY_ID = 9001

# Debug logging
$script:debugMode = $Debug.IsPresent

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    if ($script:debugMode) {
        $ts = Get-Date -Format "HH:mm:ss.fff"
        Write-Host "[$ts] [$Level] $Message" -ForegroundColor $(
            switch ($Level) {
                "ERROR" { "Red" }
                "WARN"  { "Yellow" }
                "OK"    { "Green" }
                default { "Gray" }
            }
        )
    }
}

# ============================================================================
# 2. PREFLIGHT CHECKS
# ============================================================================

if ($PSVersionTable.PSEdition -eq 'Core') {
    Write-Host "ERROR: WinWhisper requires Windows PowerShell 5.1 (powershell.exe)." -ForegroundColor Red
    Write-Host "       You are running PowerShell Core ($($PSVersionTable.PSVersion))." -ForegroundColor Red
    exit 1
}

# ============================================================================
# 3. SETTINGS SERVICE
# ============================================================================

$script:DEFAULT_SETTINGS = @{
    version        = 1
    hotkey         = @{ key = "Add"; vk = $script:VK_ADD; modifiers = 0 }
    language       = $null
    mode           = "toggle"
    autoEnter      = $false
    autoEnterDelay = 800
    doublePress    = @{ enabled = $true; interval = 400 }
    overlay        = @{ enabled = $true; showHypothesis = $true; position = "tray" }
    history        = @{ maxEntries = 20 }
    textOutput     = @{ method = "sendInput"; clipboardFallbackLength = 200 }
    autoStart      = $false
    engine         = "uwp"
}

function Load-Settings {
    if (Test-Path $script:SETTINGS_FILE) {
        try {
            $json = Get-Content $script:SETTINGS_FILE -Raw | ConvertFrom-Json
            $merged = $script:DEFAULT_SETTINGS.Clone()
            foreach ($prop in $json.PSObject.Properties) {
                $merged[$prop.Name] = $prop.Value
            }
            Write-Log "Settings loaded from $($script:SETTINGS_FILE)"
            return $merged
        } catch {
            Write-Log "Failed to load settings: $_" "WARN"
        }
    }
    Write-Log "Using default settings"
    return $script:DEFAULT_SETTINGS.Clone()
}

function Save-Settings {
    param([hashtable]$SettingsData)
    try {
        if (-not (Test-Path $script:SETTINGS_DIR)) {
            New-Item -ItemType Directory -Force -Path $script:SETTINGS_DIR | Out-Null
        }
        $SettingsData | ConvertTo-Json -Depth 4 | Set-Content $script:SETTINGS_FILE -Encoding UTF8
        Write-Log "Settings saved"
    } catch {
        Write-Log "Failed to save settings: $_" "ERROR"
    }
}

$script:config = Load-Settings

# ============================================================================
# 4. UNINSTALL
# ============================================================================

if ($Uninstall) {
    Write-Host "Uninstalling $($script:APP_NAME)..." -ForegroundColor Yellow
    if (Test-Path $script:SHORTCUT_PATH) {
        Remove-Item $script:SHORTCUT_PATH -Force
        Write-Host "  Removed startup shortcut" -ForegroundColor Gray
    }
    if (Test-Path $script:SETTINGS_DIR) {
        Remove-Item $script:SETTINGS_DIR -Recurse -Force
        Write-Host "  Removed settings" -ForegroundColor Gray
    }
    Write-Host "Uninstalled." -ForegroundColor Green
    exit 0
}

# ============================================================================
# 5. LOAD SYSTEM.SPEECH
# ============================================================================

Write-Log "Loading System.Speech..."
try {
    Add-Type -AssemblyName System.Speech
    Write-Log "System.Speech loaded" "OK"
} catch {
    Write-Host "ERROR: Failed to load System.Speech assembly: $_" -ForegroundColor Red
    exit 1
}

# ============================================================================
# 6. C# SPEECH MANAGER (System.Speech.Recognition — standard .NET events)
# ============================================================================

Write-Log "Compiling C# speech manager..."

$managerCode = @'
using System;
using System.Speech.Recognition;
using System.Text;
using System.Threading;

public class SpeechManager : IDisposable
{
    private SpeechRecognitionEngine _engine;
    private StringBuilder _accumulated = new StringBuilder();
    private string _currentHypothesis = "";
    private int _resultCount = 0;
    private int _hypothesisCount = 0;
    private volatile bool _isListening = false;
    private string _lastError = null;

    public string AccumulatedText { get { return _accumulated.ToString(); } }
    public string CurrentHypothesis { get { return _currentHypothesis; } }
    public int ResultCount { get { return _resultCount; } }
    public int HypothesisCount { get { return _hypothesisCount; } }
    public bool IsListening { get { return _isListening; } }
    public string LastError { get { return _lastError; } }

    public string Initialize(string culture)
    {
        try
        {
            if (!string.IsNullOrEmpty(culture))
            {
                var ci = new System.Globalization.CultureInfo(culture);
                _engine = new SpeechRecognitionEngine(ci);
            }
            else
            {
                _engine = new SpeechRecognitionEngine();
            }

            _engine.SetInputToDefaultAudioDevice();
            _engine.LoadGrammar(new DictationGrammar());

            // Wire events (standard .NET — these just work!)
            _engine.SpeechRecognized += OnSpeechRecognized;
            _engine.SpeechHypothesized += OnSpeechHypothesized;
            _engine.RecognizeCompleted += OnRecognizeCompleted;

            return "OK|" + _engine.RecognizerInfo.Culture.DisplayName;
        }
        catch (Exception ex)
        {
            return "ERROR: " + ex.GetType().Name + ": " + ex.Message;
        }
    }

    public void ClearAccumulated()
    {
        _accumulated.Clear();
        _resultCount = 0;
        _hypothesisCount = 0;
        _currentHypothesis = "";
        _lastError = null;
    }

    public string StartListening()
    {
        try
        {
            _engine.RecognizeAsync(RecognizeMode.Multiple);
            _isListening = true;
            return "OK";
        }
        catch (Exception ex)
        {
            _lastError = ex.Message;
            return "ERROR: " + ex.Message;
        }
    }

    public void StopListening()
    {
        try
        {
            _engine.RecognizeAsyncCancel();
        }
        catch { }
        _isListening = false;
    }

    private void OnSpeechRecognized(object sender, SpeechRecognizedEventArgs e)
    {
        if (e.Result != null && !string.IsNullOrWhiteSpace(e.Result.Text))
        {
            if (_accumulated.Length > 0) _accumulated.Append(" ");
            _accumulated.Append(e.Result.Text);
            Interlocked.Increment(ref _resultCount);
            _currentHypothesis = "";  // Clear hypothesis after final result
        }
    }

    private void OnSpeechHypothesized(object sender, SpeechHypothesizedEventArgs e)
    {
        if (e.Result != null)
        {
            _currentHypothesis = e.Result.Text;
            Interlocked.Increment(ref _hypothesisCount);
        }
    }

    private void OnRecognizeCompleted(object sender, RecognizeCompletedEventArgs e)
    {
        _isListening = false;
        if (e.Error != null)
        {
            _lastError = e.Error.Message;
        }
    }

    public void Dispose()
    {
        try { _engine.RecognizeAsyncCancel(); } catch { }
        try { _engine.Dispose(); } catch { }
    }
}
'@

try {
    Add-Type -TypeDefinition $managerCode -ReferencedAssemblies @(
        "System.Speech"
    ) -ErrorAction Stop
    Write-Log "C# speech manager compiled" "OK"
} catch {
    Write-Host "ERROR: Failed to compile speech manager: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ============================================================================
# 7. SPEECH SERVICE
# ============================================================================

$script:manager = $null
$script:isListening = $false
$script:history = @()
$script:lastHotkeyTime = [DateTime]::MinValue

function Initialize-SpeechRecognizer {
    try {
        Write-Log "Initializing speech service..."

        $script:manager = New-Object SpeechManager
        $lang = $script:config.language
        $initResult = $script:manager.Initialize($lang)

        if ($initResult.StartsWith("ERROR")) {
            throw $initResult
        }

        $parts = $initResult.Split('|')
        $culture = if ($parts.Length -gt 1) { $parts[1] } else { "unknown" }
        Write-Log "SpeechRecognitionEngine created ($culture)" "OK"

        return $true
    } catch {
        Write-Log "Speech init failed: $_" "ERROR"
        Write-Host "ERROR: Failed to initialize speech recognition:" -ForegroundColor Red
        Write-Host "       $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# NOTE: Initialize-SpeechRecognizer is called in section 14 after WinForms.

# ============================================================================
# 8. TEST SPEECH MODE (early exit)
# ============================================================================

if ($TestSpeech) {
    if (-not (Initialize-SpeechRecognizer)) { exit 1 }

    Write-Host ""
    Write-Host "=== WinWhisper: Quick Speech Test ===" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Speak a short phrase (10 second timeout)..." -ForegroundColor Yellow
    Write-Host ""

    try {
        $engine = New-Object System.Speech.Recognition.SpeechRecognitionEngine
        $engine.SetInputToDefaultAudioDevice()
        $engine.LoadGrammar((New-Object System.Speech.Recognition.DictationGrammar))
        $result = $engine.Recognize([TimeSpan]::FromSeconds(10))

        if ($result -and $result.Text.Length -gt 0) {
            Write-Host "  Confidence: $($result.Confidence)" -ForegroundColor White
            Write-Host "  Text:       $($result.Text)" -ForegroundColor White
            Write-Host ""
            Write-Host "[OK] Speech recognition is working!" -ForegroundColor Green
        } else {
            Write-Host "[WARN] No text captured. Make sure your microphone is working." -ForegroundColor Yellow
        }

        $engine.Dispose()
    } catch {
        Write-Host "[FAIL] $_" -ForegroundColor Red
    }

    $script:manager.Dispose()
    exit 0
}

# ============================================================================
# 9. LOAD WINFORMS + SINGLE-INSTANCE CHECK
# ============================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:mutex = New-Object System.Threading.Mutex($false, $script:MUTEX_NAME)
if (-not $script:mutex.WaitOne(0, $false)) {
    [System.Windows.Forms.MessageBox]::Show(
        "$($script:APP_NAME) is already running. Check the system tray.",
        $script:APP_NAME, 'OK', 'Information') | Out-Null
    exit 0
}

# ============================================================================
# 10. P/INVOKE NATIVE METHODS
# ============================================================================

Write-Log "Loading native methods..."

$nativeCode = @'
using System;
using System.Runtime.InteropServices;

public static class WinAPI
{
    [DllImport("user32.dll")]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll")]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    public const uint INPUT_KEYBOARD = 1;
    public const uint KEYEVENTF_UNICODE = 0x0004;
    public const uint KEYEVENTF_KEYUP = 0x0002;

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT
    {
        public uint type;
        public INPUTUNION union;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct INPUTUNION
    {
        [FieldOffset(0)]
        public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    public static void TypeText(string text)
    {
        if (string.IsNullOrEmpty(text)) return;

        INPUT[] inputs = new INPUT[text.Length * 2];
        for (int i = 0; i < text.Length; i++)
        {
            ushort ch = text[i];

            inputs[i * 2].type = INPUT_KEYBOARD;
            inputs[i * 2].union.ki.wVk = 0;
            inputs[i * 2].union.ki.wScan = ch;
            inputs[i * 2].union.ki.dwFlags = KEYEVENTF_UNICODE;
            inputs[i * 2].union.ki.time = 0;
            inputs[i * 2].union.ki.dwExtraInfo = IntPtr.Zero;

            inputs[i * 2 + 1].type = INPUT_KEYBOARD;
            inputs[i * 2 + 1].union.ki.wVk = 0;
            inputs[i * 2 + 1].union.ki.wScan = ch;
            inputs[i * 2 + 1].union.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
            inputs[i * 2 + 1].union.ki.time = 0;
            inputs[i * 2 + 1].union.ki.dwExtraInfo = IntPtr.Zero;
        }

        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
    }

    public static void TypeEnter()
    {
        INPUT[] inputs = new INPUT[2];

        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].union.ki.wVk = 0x0D;
        inputs[0].union.ki.dwFlags = 0;

        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].union.ki.wVk = 0x0D;
        inputs[1].union.ki.dwFlags = KEYEVENTF_KEYUP;

        SendInput(2, inputs, Marshal.SizeOf(typeof(INPUT)));
    }
}
'@

try {
    Add-Type -TypeDefinition $nativeCode -ErrorAction Stop
    Write-Log "Native methods loaded" "OK"
} catch {
    [System.Windows.Forms.MessageBox]::Show(
        "Failed to compile native methods:`n$($_.Exception.Message)",
        $script:APP_NAME, 'OK', 'Error') | Out-Null
    exit 1
}

# ============================================================================
# 11. WINFORMS: HotkeyForm + OverlayForm
# ============================================================================

Write-Log "Compiling WinForms classes..."

$formsCode = @'
using System;
using System.Drawing;
using System.Windows.Forms;

public class HotkeyForm : Form
{
    public event EventHandler HotkeyPressed;

    public HotkeyForm()
    {
        this.Visible = false;
        this.ShowInTaskbar = false;
        this.FormBorderStyle = FormBorderStyle.None;
        this.WindowState = FormWindowState.Minimized;
        this.Text = "WinWhisper_HotkeyForm";
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == 0x0312) // WM_HOTKEY
        {
            var h = HotkeyPressed;
            if (h != null) h(this, EventArgs.Empty);
        }
        base.WndProc(ref m);
    }
}

public class OverlayForm : Form
{
    private Label _label;
    private Panel _dot;

    public OverlayForm()
    {
        this.FormBorderStyle = FormBorderStyle.None;
        this.TopMost = true;
        this.ShowInTaskbar = false;
        this.StartPosition = FormStartPosition.Manual;
        this.BackColor = Color.FromArgb(30, 30, 30);
        this.Opacity = 0.92;
        this.Size = new Size(320, 44);

        _dot = new Panel();
        _dot.Size = new Size(10, 10);
        _dot.Location = new Point(14, 17);
        _dot.BackColor = Color.FromArgb(239, 68, 68);
        this.Controls.Add(_dot);

        _label = new Label();
        _label.ForeColor = Color.FromArgb(220, 220, 220);
        _label.Font = new Font("Segoe UI", 10f, FontStyle.Regular);
        _label.AutoSize = false;
        _label.Size = new Size(280, 24);
        _label.Location = new Point(32, 10);
        _label.TextAlign = ContentAlignment.MiddleLeft;
        this.Controls.Add(_label);

        PositionNearTray();
    }

    public void SetText(string text)
    {
        if (this.InvokeRequired)
            this.BeginInvoke(new Action(() => UpdateText(text)));
        else
            UpdateText(text);
    }

    private void UpdateText(string text)
    {
        if (text != null && text.Length > 45)
            text = "..." + text.Substring(text.Length - 42);
        _label.Text = text;
    }

    public void SetDotColor(Color color)
    {
        if (this.InvokeRequired)
            this.BeginInvoke(new Action(() => _dot.BackColor = color));
        else
            _dot.BackColor = color;
    }

    public void PositionNearTray()
    {
        var screen = Screen.PrimaryScreen.WorkingArea;
        this.Location = new Point(screen.Right - this.Width - 10, screen.Bottom - this.Height - 10);
    }

    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x80000;    // WS_EX_LAYERED
            cp.ExStyle |= 0x20;       // WS_EX_TRANSPARENT (click-through)
            cp.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
            cp.ExStyle |= 0x80;       // WS_EX_TOOLWINDOW (hide from Alt+Tab)
            return cp;
        }
    }

    protected override bool ShowWithoutActivation { get { return true; } }
}
'@

try {
    Add-Type -TypeDefinition $formsCode -ReferencedAssemblies @(
        "System.Windows.Forms",
        "System.Drawing"
    ) -ErrorAction Stop
    Write-Log "WinForms classes compiled" "OK"
} catch {
    [System.Windows.Forms.MessageBox]::Show(
        "Failed to compile WinForms classes:`n$($_.Exception.Message)",
        $script:APP_NAME, 'OK', 'Error') | Out-Null
    exit 1
}

# ============================================================================
# 12. SPEECH CONTROL FUNCTIONS
# ============================================================================

function Start-Listening {
    if ($script:isListening) { return }
    try {
        $script:manager.ClearAccumulated()
        $script:lastResultCount = 0
        $script:lastHypothesisCount = 0

        $startResult = $script:manager.StartListening()
        if ($startResult -ne "OK") {
            throw $startResult
        }

        $script:isListening = $true
        Write-Log "Listening started" "OK"
    } catch {
        Write-Log "Start failed: $_" "ERROR"
        $script:isListening = $false
    }
}

function Stop-Listening {
    if (-not $script:isListening) { return "" }
    $script:isListening = $false

    $script:manager.StopListening()

    $text = $script:manager.AccumulatedText
    Write-Log "Listening stopped. Results=$($script:manager.ResultCount) Hypotheses=$($script:manager.HypothesisCount) Text='$text'" "OK"
    if ($script:manager.LastError) {
        Write-Log "Manager last error: $($script:manager.LastError)" "WARN"
    }

    return $text
}

function Add-History([string]$text) {
    if (-not $text) { return }
    $maxEntries = 20
    if ($script:config.history -and $script:config.history.maxEntries) {
        $maxEntries = $script:config.history.maxEntries
    }
    $script:history = @($text) + $script:history
    if ($script:history.Count -gt $maxEntries) {
        $script:history = $script:history[0..($maxEntries - 1)]
    }
}

# ============================================================================
# 13. TRAY ICON
# ============================================================================

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

# ============================================================================
# 14. BUILD UI
# ============================================================================

Write-Log "Starting $($script:APP_NAME) v$($script:VERSION)..."

# Create hidden hotkey form
$script:hotkeyForm = New-Object HotkeyForm

# NOW initialize speech recognizer (after WinForms sync context exists)
if (-not (Initialize-SpeechRecognizer)) {
    exit 1
}

# Register global hotkey
$hotkeyVk = $script:VK_ADD
$hotkeyMod = [uint32]0
if ($script:config.hotkey) {
    if ($script:config.hotkey.vk) { $hotkeyVk = $script:config.hotkey.vk }
    if ($script:config.hotkey.modifiers) { $hotkeyMod = [uint32]$script:config.hotkey.modifiers }
}

$registered = [WinAPI]::RegisterHotKey($script:hotkeyForm.Handle, $script:HOTKEY_ID, $hotkeyMod, [uint32]$hotkeyVk)
if (-not $registered) {
    $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    Write-Log "RegisterHotKey failed (error $err)" "ERROR"
    [System.Windows.Forms.MessageBox]::Show(
        "Failed to register hotkey. It may be in use by another application.`nError code: $err",
        $script:APP_NAME, 'OK', 'Warning') | Out-Null
}
Write-Log "Hotkey registered (VK=$hotkeyVk, MOD=$hotkeyMod)" "OK"

# Create overlay
$script:overlay = New-Object OverlayForm

# Polling timer: updates overlay with hypothesis/result text from the manager
# (runs on WinForms UI thread, so it works during Application.Run)
$script:lastResultCount = 0
$script:lastHypothesisCount = 0
$script:pollTimer = New-Object System.Windows.Forms.Timer
$script:pollTimer.Interval = 150  # 150ms poll interval
$script:pollTimer.Add_Tick({
    if ($script:isListening -and $script:manager) {
        # Show hypothesis text (real-time partial recognition)
        $hCount = $script:manager.HypothesisCount
        if ($hCount -gt $script:lastHypothesisCount) {
            $script:lastHypothesisCount = $hCount
            $hyp = $script:manager.CurrentHypothesis
            $acc = $script:manager.AccumulatedText
            $displayText = if ($acc -and $hyp) { "$acc $hyp..." } elseif ($hyp) { "$hyp..." } elseif ($acc) { $acc } else { "Listening..." }
            $script:overlay.SetText($displayText)
        }

        # Show final result text
        $rCount = $script:manager.ResultCount
        if ($rCount -gt $script:lastResultCount) {
            $script:lastResultCount = $rCount
            $script:overlay.SetText($script:manager.AccumulatedText)
        }
    }
})
$script:pollTimer.Start()

# Create tray icon
$script:trayIcon = New-Object System.Windows.Forms.NotifyIcon
$script:trayIcon.Text = "$($script:APP_NAME) - Ready"
$script:trayIcon.Icon = New-TrayIcon "idle"
$script:trayIcon.Visible = $true

# Tray context menu
$menu = New-Object System.Windows.Forms.ContextMenuStrip

$menuStatus = $menu.Items.Add("Ready (Numpad+ to dictate)")
$menuStatus.Enabled = $false
$menuStatus.Font = New-Object System.Drawing.Font($menuStatus.Font, [System.Drawing.FontStyle]::Bold)

$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$menuCopyLast = $menu.Items.Add("Copy last transcription")
$menuCopyLast.Add_Click({
    if ($script:history.Count -gt 0) {
        [System.Windows.Forms.Clipboard]::SetText($script:history[0])
        $script:trayIcon.ShowBalloonTip(1500, $script:APP_NAME, "Copied to clipboard!", [System.Windows.Forms.ToolTipIcon]::Info)
    } else {
        $script:trayIcon.ShowBalloonTip(1500, $script:APP_NAME, "No transcription history yet.", [System.Windows.Forms.ToolTipIcon]::Info)
    }
})

$menuHistory = New-Object System.Windows.Forms.ToolStripMenuItem("History")
$menuHistory.Enabled = $false
$menu.Items.Add($menuHistory) | Out-Null

$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$menuAutoEnter = $menu.Items.Add("Auto-Enter after dictation")
$menuAutoEnter.CheckOnClick = $true
$menuAutoEnter.Checked = [bool]$script:config.autoEnter
$menuAutoEnter.Add_Click({
    $script:config.autoEnter = $menuAutoEnter.Checked
    Save-Settings $script:config
})

$menuAutoStart = $menu.Items.Add("Start with Windows")
$menuAutoStart.CheckOnClick = $true
$menuAutoStart.Checked = [bool]$script:config.autoStart
$menuAutoStart.Add_Click({
    $script:config.autoStart = $menuAutoStart.Checked
    Save-Settings $script:config
    if ($script:config.autoStart) {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($script:SHORTCUT_PATH)
        $shortcut.TargetPath = "powershell.exe"
        $shortcut.Arguments = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$($script:SCRIPT_PATH)`""
        $shortcut.WorkingDirectory = (Split-Path $script:SCRIPT_PATH)
        $shortcut.Save()
    } else {
        if (Test-Path $script:SHORTCUT_PATH) { Remove-Item $script:SHORTCUT_PATH }
    }
})

$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$menuExit = $menu.Items.Add("Exit")
$menuExit.Add_Click({
    Write-Log "Exit requested"
    Exit-App
})

$script:trayIcon.ContextMenuStrip = $menu

# Menu opening: update history submenu
$menu.Add_Opening({
    $menuHistory.DropDownItems.Clear()
    if ($script:history.Count -eq 0) {
        $menuHistory.Enabled = $false
    } else {
        $menuHistory.Enabled = $true
        $count = [Math]::Min($script:history.Count, 5)
        for ($i = 0; $i -lt $count; $i++) {
            $text = $script:history[$i]
            $display = if ($text.Length -gt 50) { $text.Substring(0, 50) + "..." } else { $text }
            $item = $menuHistory.DropDownItems.Add($display)
            $capturedText = $text
            $item.Add_Click([ScriptBlock]::Create("
                [System.Windows.Forms.Clipboard]::SetText('$($capturedText -replace "'","''")')
                `$script:trayIcon.ShowBalloonTip(1500, '$($script:APP_NAME)', 'Copied to clipboard!', [System.Windows.Forms.ToolTipIcon]::Info)
            "))
        }
    }
})

# ============================================================================
# 15. HOTKEY TOGGLE LOGIC
# ============================================================================

$script:hotkeyForm.Add_HotkeyPressed({
    $now = [DateTime]::Now
    $timeSinceLast = ($now - $script:lastHotkeyTime).TotalMilliseconds
    $script:lastHotkeyTime = $now

    $doublePressEnabled = $false
    $doublePressInterval = 400
    if ($script:config.doublePress) {
        $doublePressEnabled = [bool]$script:config.doublePress.enabled
        if ($script:config.doublePress.interval) {
            $doublePressInterval = $script:config.doublePress.interval
        }
    }
    $isDoublePress = $doublePressEnabled -and ($timeSinceLast -lt $doublePressInterval) -and ($timeSinceLast -gt 50)

    if ($script:isListening) {
        # === STOP ===
        Write-Log "Stopping..."

        $script:overlay.SetText("Finishing...")
        $script:overlay.SetDotColor([System.Drawing.Color]::FromArgb(234, 179, 8))

        $text = Stop-Listening

        $script:trayIcon.Icon = New-TrayIcon "idle"
        $script:trayIcon.Text = "$($script:APP_NAME) - Ready"
        $menuStatus.Text = "Ready (Numpad+ to dictate)"

        if ($text -and $text.Length -gt 0) {
            $script:overlay.SetText("Done!")
            $script:overlay.SetDotColor([System.Drawing.Color]::FromArgb(34, 197, 94))

            Add-History $text

            # Type text into focused field
            [WinAPI]::TypeText($text)
            Write-Log "Text typed: '$text'" "OK"

            # Auto-Enter logic
            $shouldEnter = [bool]$script:config.autoEnter -or $isDoublePress
            if ($shouldEnter) {
                $delay = 800
                if ($script:config.autoEnterDelay) { $delay = $script:config.autoEnterDelay }

                $enterTimer = New-Object System.Windows.Forms.Timer
                $enterTimer.Interval = $delay
                $enterTimer.Add_Tick({
                    $this.Stop()
                    $this.Dispose()
                    [WinAPI]::TypeEnter()
                    Write-Log "Enter sent" "OK"
                })
                $enterTimer.Start()
            }
        } else {
            $script:overlay.SetText("No speech detected")
            $script:overlay.SetDotColor([System.Drawing.Color]::Gray)
        }

        # Hide overlay after brief display
        $hideTimer = New-Object System.Windows.Forms.Timer
        $hideTimer.Interval = 1500
        $hideTimer.Add_Tick({
            $this.Stop()
            $this.Dispose()
            $script:overlay.Hide()
        })
        $hideTimer.Start()

    } else {
        # === START ===
        Write-Log "Starting..."

        $script:overlay.SetText("Listening...")
        $script:overlay.SetDotColor([System.Drawing.Color]::FromArgb(239, 68, 68))
        $script:overlay.Show()

        Start-Listening

        $script:trayIcon.Icon = New-TrayIcon "recording"
        $script:trayIcon.Text = "$($script:APP_NAME) - Listening..."
        $menuStatus.Text = "Listening... (Numpad+ to stop)"

        if ($isDoublePress) {
            Write-Log "Double-press detected (will auto-Enter on stop)"
        }
    }
})

# ============================================================================
# 16. CLEANUP + EXIT
# ============================================================================

function Exit-App {
    Write-Log "Cleaning up..."

    try { $script:pollTimer.Stop(); $script:pollTimer.Dispose() } catch {}
    try { [WinAPI]::UnregisterHotKey($script:hotkeyForm.Handle, $script:HOTKEY_ID) | Out-Null } catch {}

    if ($script:isListening) {
        try { $script:manager.StopListening() } catch {}
    }

    try { $script:manager.Dispose() } catch {}
    try { $script:overlay.Close(); $script:overlay.Dispose() } catch {}
    try { $script:trayIcon.Visible = $false; $script:trayIcon.Dispose() } catch {}
    try { $script:mutex.ReleaseMutex() } catch {}

    Write-Log "Goodbye!" "OK"
    [System.Windows.Forms.Application]::Exit()
}

$script:hotkeyForm.Add_FormClosing({
    Exit-App
})

# ============================================================================
# 17. RUN
# ============================================================================

if ($script:debugMode) {
    Write-Host ""
    Write-Host "=== $($script:APP_NAME) v$($script:VERSION) ===" -ForegroundColor Cyan
    Write-Host "  Hotkey:   Numpad+ (toggle)" -ForegroundColor Gray
    Write-Host "  Language: $(if ($script:config.language) { $script:config.language } else { 'system default' })" -ForegroundColor Gray
    Write-Host "  Engine:   System.Speech (local)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Press Numpad+ to start/stop dictation." -ForegroundColor White
    Write-Host "  Right-click tray icon for menu." -ForegroundColor White
    Write-Host ""
}

$script:trayIcon.ShowBalloonTip(
    2000,
    $script:APP_NAME,
    "Press Numpad+ to start voice dictation.",
    [System.Windows.Forms.ToolTipIcon]::Info
)

# Run the message loop
[System.Windows.Forms.Application]::Run($script:hotkeyForm)
