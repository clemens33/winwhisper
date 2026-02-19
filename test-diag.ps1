# Diagnostic: which parent-process feature breaks engine speech capture?
# Run each test and speak into mic during the 5-second window.
param(
    [int]$Test = 0  # 0-4=basic, 5=poll timer, 6=tray icon, 7=overlay shown, 8=start via hotkey
)

$enginePath = Join-Path $PSScriptRoot 'winwhisper-engine.exe'

# Kill any stale engines
Get-Process winwhisper-engine -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

Write-Host "=== Diagnostic Test $Test ===" -ForegroundColor Cyan

switch ($Test) {
    0 { Write-Host "Baseline (same as test-engine.ps1)" -ForegroundColor Gray }
    1 { Write-Host "With WinForms assembly loaded" -ForegroundColor Gray }
    2 { Write-Host "With WinForms + hidden form created" -ForegroundColor Gray }
    3 { Write-Host "With WinForms + form + DoEvents loop" -ForegroundColor Gray }
    4 { Write-Host "With WinForms + form + DoEvents + hotkey registered" -ForegroundColor Gray }
    5 { Write-Host "With poll timer (100ms WinForms.Timer)" -ForegroundColor Gray }
    6 { Write-Host "With NotifyIcon (tray icon)" -ForegroundColor Gray }
    7 { Write-Host "With topmost overlay shown during recording" -ForegroundColor Gray }
    8 { Write-Host "Overlay: TopMost only (no Opacity)" -ForegroundColor Gray }
    9 { Write-Host "Overlay: Opacity only (no TopMost)" -ForegroundColor Gray }
    10 { Write-Host "Overlay: plain visible form (no TopMost, no Opacity)" -ForegroundColor Gray }
}

# Conditionally load WinForms
if ($Test -ge 1) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Write-Host "  [loaded WinForms]" -ForegroundColor DarkGray
}

# Conditionally create a form
$form = $null
if ($Test -ge 2) {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Diag"
    $form.ShowInTaskbar = $false
    $form.WindowState = 'Minimized'
    $form.Visible = $false
    Write-Host "  [created hidden form]" -ForegroundColor DarkGray
}

# Conditionally register hotkey (only for tests 4-10, not higher)
if ($Test -ge 4) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class HotkeyHelper {
    [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, int fsModifiers, int vk);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
}
"@
    $form.Visible = $true
    $form.WindowState = 'Minimized'
    [HotkeyHelper]::RegisterHotKey($form.Handle, 1, 0, 0x6B) | Out-Null  # Numpad+
    Write-Host "  [registered hotkey]" -ForegroundColor DarkGray
}

# Start engine
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $enginePath
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true

$proc = New-Object System.Diagnostics.Process
$proc.StartInfo = $psi
$proc.Start() | Out-Null

$l1 = $proc.StandardOutput.ReadLine()
$l2 = $proc.StandardOutput.ReadLine()
Write-Host "  $l1"
Write-Host "  $l2"

# Background reader
$queue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$reader = [PowerShell]::Create()
$null = $reader.AddScript({
    param($stdout, $q)
    while ($true) {
        $line = $stdout.ReadLine()
        if ($line -eq $null) { break }
        $q.Enqueue($line)
    }
}).AddArgument($proc.StandardOutput).AddArgument($queue)
$readerHandle = $reader.BeginInvoke()

# Stderr reader
$stderrReader = [PowerShell]::Create()
$null = $stderrReader.AddScript({
    param($stderr, $q)
    while ($true) {
        $line = $stderr.ReadLine()
        if ($line -eq $null) { break }
        $q.Enqueue("STDERR:$line")
    }
}).AddArgument($proc.StandardError).AddArgument($queue)
$stderrHandle = $stderrReader.BeginInvoke()

# Conditionally add poll timer
$pollTimer = $null
if ($Test -ge 5) {
    $pollTimer = New-Object System.Windows.Forms.Timer
    $pollTimer.Interval = 100
    $pollTimer.Add_Tick({})  # empty tick, just to have it running
    $pollTimer.Start()
    Write-Host "  [poll timer started]" -ForegroundColor DarkGray
}

# Conditionally add tray icon
$trayIcon = $null
if ($Test -ge 6) {
    $trayIcon = New-Object System.Windows.Forms.NotifyIcon
    $trayIcon.Text = "Diag Test"
    $bmp = New-Object System.Drawing.Bitmap(16, 16)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.FillEllipse([System.Drawing.Brushes]::Gray, 3, 3, 10, 10)
    $g.Dispose()
    $trayIcon.Icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $trayIcon.Visible = $true
    Write-Host "  [tray icon visible]" -ForegroundColor DarkGray
}

# Conditionally create overlay
$overlay = $null
if ($Test -ge 7) {
    $overlay = New-Object System.Windows.Forms.Form
    $overlay.FormBorderStyle = 'None'
    $overlay.ShowInTaskbar = $false
    $overlay.Size = New-Object System.Drawing.Size(320, 44)
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $overlay.Location = New-Object System.Drawing.Point(($screen.Right - 330), ($screen.Bottom - 54))

    if ($Test -eq 7) {
        $overlay.TopMost = $true
        $overlay.Opacity = 0.92
        $overlay.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
        Write-Host "  [overlay: TopMost + Opacity]" -ForegroundColor DarkGray
    } elseif ($Test -eq 8) {
        $overlay.TopMost = $true
        $overlay.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
        Write-Host "  [overlay: TopMost only]" -ForegroundColor DarkGray
    } elseif ($Test -eq 9) {
        $overlay.Opacity = 0.92
        $overlay.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
        Write-Host "  [overlay: Opacity only]" -ForegroundColor DarkGray
    } elseif ($Test -eq 10) {
        $overlay.BackColor = [System.Drawing.Color]::Red
        Write-Host "  [overlay: plain form]" -ForegroundColor DarkGray
    }
}

# Test 8: wait for hotkey press to send start
$script:hotkeyStarted = $false
if ($Test -ge 8) {
    Write-Host ''
    Write-Host 'Press Numpad+ to start recording, then speak for 5 seconds...' -ForegroundColor Yellow
    # Wait for hotkey in DoEvents loop
    while (-not $script:hotkeyStarted) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 10
        # Check for WM_HOTKEY (0x0312) - but since our form doesn't have WndProc override,
        # we use a timer to check a flag set by PeekMessage... actually, simpler:
        # just poll the keyboard state
    }
}

# Send start (for tests 0-7, send immediately)
if ($Test -lt 8) {
    Write-Host ''
    Write-Host 'Sending start... SPEAK NOW for 5 seconds!' -ForegroundColor Green
    $proc.StandardInput.WriteLine('start')
    $proc.StandardInput.Flush()
    if ($overlay) {
        $overlay.Show()
        Write-Host "  [overlay shown]" -ForegroundColor DarkGray
    }
}

# Wait 5 seconds - either with DoEvents or Start-Sleep
$hypothesisCount = 0
for ($i = 0; $i -lt 500; $i++) {
    if ($Test -ge 3) {
        [System.Windows.Forms.Application]::DoEvents()
    }
    Start-Sleep -Milliseconds 10

    # Drain queue
    $line = $null
    while ($queue.TryDequeue([ref]$line)) {
        if ($line.StartsWith('STDERR:')) {
            Write-Host "  [stderr] $($line.Substring(7))" -ForegroundColor DarkYellow
        } else {
            Write-Host "  $line"
            if ($line.Contains('"hypothesis"')) { $hypothesisCount++ }
        }
    }
}

Write-Host ''
Write-Host 'Sending stop...' -ForegroundColor Yellow
$proc.StandardInput.WriteLine('stop')
$proc.StandardInput.Flush()
if ($overlay) { $overlay.Hide() }
Start-Sleep -Seconds 3

# Drain remaining
$line = $null
while ($queue.TryDequeue([ref]$line)) {
    if ($line.StartsWith('STDERR:')) {
        Write-Host "  [stderr] $($line.Substring(7))" -ForegroundColor DarkYellow
    } else {
        Write-Host "  $line"
    }
}

$proc.StandardInput.WriteLine('quit')
$proc.StandardInput.Flush()
Start-Sleep -Milliseconds 500

# Cleanup
if ($pollTimer) { $pollTimer.Stop(); $pollTimer.Dispose() }
if ($trayIcon) { $trayIcon.Visible = $false; $trayIcon.Dispose() }
if ($overlay) { $overlay.Close(); $overlay.Dispose() }
if ($Test -ge 4) {
    [HotkeyHelper]::UnregisterHotKey($form.Handle, 1) | Out-Null
}
if ($form) { $form.Close(); $form.Dispose() }
$reader.EndInvoke($readerHandle) | Out-Null
$reader.Dispose()
$stderrReader.EndInvoke($stderrHandle) | Out-Null
$stderrReader.Dispose()
if (-not $proc.HasExited) { $proc.Kill() }

Write-Host ''
if ($hypothesisCount -gt 0) {
    Write-Host "RESULT: PASS - Got $hypothesisCount hypothesis events" -ForegroundColor Green
} else {
    Write-Host "RESULT: FAIL - No hypothesis events captured" -ForegroundColor Red
}
Write-Host ''
