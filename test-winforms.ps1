# Test: does WinForms Application.Run() in the parent affect engine speech?
# This mimics the full app's environment (WinForms + poll timer) with the engine.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$enginePath = Join-Path $PSScriptRoot 'winwhisper-engine.exe'
Write-Host "Engine: $enginePath" -ForegroundColor Cyan

# Start engine (same as full app)
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

# Read init lines
$l1 = $proc.StandardOutput.ReadLine()
$l2 = $proc.StandardOutput.ReadLine()
Write-Host "  $l1"
Write-Host "  $l2"

# Background stdout reader into ConcurrentQueue (same as full app)
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

# Background stderr reader (diagnostic)
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

# Create a WinForms form (like the full app does)
$form = New-Object System.Windows.Forms.Form
$form.Text = "WinForms Engine Test"
$form.Size = New-Object System.Drawing.Size(300, 100)
$form.StartPosition = 'CenterScreen'
$form.TopMost = $true

$label = New-Object System.Windows.Forms.Label
$label.Text = "Testing speech... watch console"
$label.Dock = 'Fill'
$label.TextAlign = 'MiddleCenter'
$form.Controls.Add($label)

# Poll timer (same pattern as full app)
$pollTimer = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = 100
$pollTimer.Add_Tick({
    $line = $null
    while ($queue.TryDequeue([ref]$line)) {
        if ($line.StartsWith('STDERR:')) {
            Write-Host "  [stderr] $($line.Substring(7))" -ForegroundColor DarkYellow
        } else {
            Write-Host "  $line"
        }
    }
})
$pollTimer.Start()

# Timer: send 'start' after 1 second
$startTimer = New-Object System.Windows.Forms.Timer
$startTimer.Interval = 1000
$startTimer.Add_Tick({
    $startTimer.Stop()
    $startTimer.Dispose()
    Write-Host ''
    Write-Host 'Sending start... SPEAK NOW for 5 seconds!' -ForegroundColor Green
    $proc.StandardInput.WriteLine('start')
    $proc.StandardInput.Flush()

    # Timer: send 'stop' after 5 seconds
    $stopTimer = New-Object System.Windows.Forms.Timer
    $stopTimer.Interval = 5000
    $stopTimer.Add_Tick({
        $stopTimer.Stop()
        $stopTimer.Dispose()
        Write-Host ''
        Write-Host 'Sending stop...' -ForegroundColor Yellow
        $proc.StandardInput.WriteLine('stop')
        $proc.StandardInput.Flush()

        # Timer: quit after 3 seconds
        $quitTimer = New-Object System.Windows.Forms.Timer
        $quitTimer.Interval = 3000
        $quitTimer.Add_Tick({
            $quitTimer.Stop()
            $quitTimer.Dispose()
            $proc.StandardInput.WriteLine('quit')
            $proc.StandardInput.Flush()
            Start-Sleep -Milliseconds 500
            $pollTimer.Stop()
            $form.Close()
        })
        $quitTimer.Start()
    })
    $stopTimer.Start()
})
$startTimer.Start()

Write-Host ''
Write-Host 'Running WinForms Application.Run() - same as full app...' -ForegroundColor Cyan

# THIS is the key: run WinForms message loop just like the full app
[System.Windows.Forms.Application]::Run($form)

# Cleanup
$reader.EndInvoke($readerHandle) | Out-Null
$reader.Dispose()
$stderrReader.EndInvoke($stderrHandle) | Out-Null
$stderrReader.Dispose()
if (-not $proc.HasExited) { $proc.Kill() }
Write-Host 'Done.'
