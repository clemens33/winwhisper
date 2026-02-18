# Engine integration test
# Uses a .NET thread for non-blocking stdout reading
$enginePath = Join-Path $PSScriptRoot 'winwhisper-engine.exe'
Write-Host ('Engine: ' + $enginePath)

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $enginePath
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.CreateNoWindow = $true

$proc = New-Object System.Diagnostics.Process
$proc.StartInfo = $psi
$proc.Start() | Out-Null

# Read init lines (blocking, expected)
$l1 = $proc.StandardOutput.ReadLine()
$l2 = $proc.StandardOutput.ReadLine()
Write-Host ('  ' + $l1)
Write-Host ('  ' + $l2)

# Start background reader that reads stdout and stores in a shared variable
# We use ReadLine in a loop (synchronous, on a background thread)
$script:outputDone = $false
$readJob = [PowerShell]::Create()
$readJob.AddScript({
    param($stdout)
    while ($true) {
        $line = $stdout.ReadLine()
        if ($line -eq $null) { break }
        # Write directly to host via console
        [Console]::WriteLine('  ' + $line)
    }
}).AddArgument($proc.StandardOutput)
$readHandle = $readJob.BeginInvoke()

Write-Host ''
Write-Host 'Sending start... SPEAK INTO YOUR MIC for 5 seconds!' -ForegroundColor Green
$proc.StandardInput.WriteLine('start')
$proc.StandardInput.Flush()

Start-Sleep -Seconds 5

Write-Host ''
Write-Host 'Sending stop...' -ForegroundColor Yellow
$proc.StandardInput.WriteLine('stop')
$proc.StandardInput.Flush()

Start-Sleep -Seconds 2

Write-Host 'Sending quit...' -ForegroundColor Gray
$proc.StandardInput.WriteLine('quit')
$proc.StandardInput.Flush()

Start-Sleep -Seconds 1

# Clean up
$readJob.EndInvoke($readHandle) | Out-Null
$readJob.Dispose()

if (-not $proc.HasExited) { $proc.Kill() }
Write-Host 'Done.'
